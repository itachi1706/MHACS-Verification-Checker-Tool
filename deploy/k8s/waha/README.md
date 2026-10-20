# WAHA on DigitalOcean Kubernetes

WAHA (WhatsApp HTTP API, Core, GOWS engine) plus an nginx **mTLS proxy** sidecar, managed
by Argo CD with Kustomize.

```
deploy/
├─ argocd/waha.yaml                   Argo CD Application
└─ k8s/waha/
   ├─ base/                           Namespace, Deployment (WAHA + mtls-proxy), Service, NetworkPolicy, VMServiceScrape
   ├─ components/local-sessions/      optional: sessions on a PVC instead of Postgres
   └─ overlays/
      ├─ ingress-nginx/               today: TCP 9443 via ingress-nginx tcp-services
      └─ cilium-gateway/              later: TLSRoute (TLS passthrough) on the shared Gateway
```

How a request travels: Lambda → `https://waha.<domain>:9443` → DO load balancer (existing)
→ ingress-nginx TCP stream, or a Cilium Gateway TLS passthrough listener → `mtls-proxy`
(checks the client certificate, allows only `/api/*`) → WAHA on `127.0.0.1:3000`.
TLS always terminates in the pod, so the edge never needs to support client certificates.

## 0. Session storage: Postgres

WAHA Core stores the WhatsApp login and the GOWS message store (used for history catch-up)
in **Postgres**. WAHA has no MySQL support: in the image, the only storage backends are
local SQLite files, Postgres and MongoDB, and the GOWS engine only accepts SQLite or
Postgres.

**Which option:**
- **You already have a DO managed Postgres cluster** → use it (steps below). US$0 extra.
- **Your existing DB is MySQL only** → **don't** create a Postgres cluster just for this
  (the smallest DO managed Postgres is about US$15/month, over budget). Use the PVC instead:
  enable `components/local-sessions` in the overlay and leave out
  `WHATSAPP_SESSIONS_POSTGRESQL_URL`. That costs about US$0.10/month. You lose backups,
  but losing the volume only means re-linking the bot.

### 0.1 Configure DO managed Postgres

Needs `doctl` (authenticated) and `psql`.

1. **Find the cluster and its private connection details**
   ```bash
   doctl databases list                                   # note the ID (engine: pg)
   doctl databases connection <db-id> --private           # private host, port 25060, doadmin password
   ```
2. **Allow the Kubernetes cluster** (Trusted sources)
   ```bash
   doctl kubernetes cluster list                          # note the cluster ID
   doctl databases firewalls append <db-id> --rule k8s:<cluster-id>
   ```
   Or in the control panel: Databases → your cluster → Settings → Trusted sources → add the
   Kubernetes cluster.
3. **Create the user and databases** as `doadmin`, from a machine on the trusted list (e.g.
   your IP, temporarily) or from a pod in the cluster:
   ```bash
   kubectl run psql --rm -it --restart=Never --image=postgres:17-alpine -- \
     psql "postgresql://doadmin:<doadmin-password>@<private-host>:25060/defaultdb?sslmode=require"
   ```
   ```sql
   CREATE ROLE waha LOGIN PASSWORD '<openssl rand -hex 24>';
   -- Pre-create both databases so WAHA doesn't need CREATEDB:
   CREATE DATABASE waha_mhacs         OWNER waha;   -- main  (waha_<WAHA_NAMESPACE>)
   CREATE DATABASE waha_mhacs_default OWNER waha;   -- session "default"
   ```
   As database owner, `waha` can create its tables in the `public` schema (PG 15+ makes
   the database owner the owner of `public`).
4. **Check connection headroom.** WAHA keeps a few small pools (expect about 10–20
   connections). Find the plan's limit in the control panel (database → Overview /
   Insights), or:
   ```sql
   SHOW max_connections;
   SELECT count(*) FROM pg_stat_activity;
   ```
5. **Connection string.** `base/secrets.yaml` builds it from OpenBao (§2):
   ```
   postgres://<db_user>:<db_password>@<common host>:<common port>/waha_mhacs?sslmode=require
   ```
   `kv/data/k8s/common/postgres#host` must be the **private** VPC hostname, and `#port` the
   direct port (25060).
   - Connect **directly** on 25060, not through a PgBouncer connection pool.
   - WAHA uses TLS but doesn't verify the server certificate (Node `rejectUnauthorized:
     false`). That's acceptable on the private VPC hostname.
   - Use a password **without special characters** (e.g. `openssl rand -hex 24`). WAHA
     reads the password from the URL without percent-decoding it, so a URL-encoded
     password would fail to authenticate.
6. **After deploying, verify:**
   ```bash
   kubectl -n mhacs-verify logs deploy/waha -c waha | grep -i "postgres storage"
   # -> "Using Postgres storage for session info."
   ```
   ```sql
   SELECT datname, count(*) FROM pg_stat_activity WHERE usename = 'waha' GROUP BY 1;
   ```

DO's managed Postgres includes daily backups and point-in-time recovery, so the bot's
login is backed up too.

## 1. Certificates

```bash
scripts/certs.sh waha.<your-domain>     # writes ./certs (gitignored)
```

Keep `certs/ca.key` offline (e.g. in a password manager). The Lambdas get `ca.crt`,
`client.crt` and `client.key` later as SST secrets.

## 2. Secrets (OpenBao + argocd-vault-plugin)

`base/secrets.yaml` defines both Secrets with argocd-vault-plugin placeholders
(`<path:kv/data/...#key>`). Argo CD fills them from OpenBao when it renders the manifests,
the same way as your other apps. Nothing secret is committed.

| Secret / key | OpenBao path `#key` |
|---|---|
| `waha-env` `WAHA_API_KEY` | `kv/data/k8s/mhacs-verify/waha#api_key` |
| `waha-env` `WHATSAPP_HOOK_HMAC_KEY` | `kv/data/k8s/mhacs-verify/waha#hook_hmac_key` |
| `waha-env` `WHATSAPP_HOOK_URL` | `kv/data/k8s/mhacs-verify/waha#hook_url` |
| `waha-env` `WHATSAPP_SESSIONS_POSTGRESQL_URL` | built from `kv/data/k8s/mhacs-verify/waha#db_user`, `#db_password` and the shared `kv/data/k8s/common/postgres#host`, `#port` |
| `waha-mtls` `tls.crt` / `tls.key` / `ca.crt` | `kv/data/k8s/mhacs-verify/waha-mtls#tls_crt` / `#tls_key` / `#ca_crt` |

Write the values (KV v2 mounted at `kv`; the CLI path omits `/data/`):

```bash
bao kv put kv/k8s/mhacs-verify/waha \
  api_key="$(openssl rand -hex 32)" \
  hook_hmac_key="$(openssl rand -hex 32)" \
  hook_url="" \
  db_user=waha \
  db_password="<hex password from §0.1>"

bao kv put kv/k8s/mhacs-verify/waha-mtls \
  tls_crt=@certs/server.crt \
  tls_key=@certs/server.key \
  ca_crt=@certs/ca.crt
```

- **`hook_url`** stays empty (no webhooks) until the SST app is deployed. Then set it with
  `bao kv patch kv/k8s/mhacs-verify/waha hook_url=https://<webhook-lambda-url>/waha`. If
  your AVP setup rejects empty values, use a placeholder such as `https://example.invalid/waha`.
- **Why a dedicated `waha` user:** only the host and port come from the shared
  `k8s/common/postgres` entry. The user gets its own hex password because WAHA reads
  the password from the URL without percent-decoding it, so a shared password with special
  characters would fail. If the shared user's password is plain alphanumeric and it owns
  the two databases, you can point `db_user`/`db_password` at `k8s/common/postgres` instead.
- **AVP's OpenBao policy** must allow reading `kv/data/k8s/mhacs-verify/*` as well as
  `kv/data/k8s/common/*`. For example:
  ```hcl
  path "kv/data/k8s/mhacs-verify/*" { capabilities = ["read"] }
  ```
- The Lambdas need `api_key` and `hook_hmac_key` too. Copy them into SST secrets
  (`sst secret set ...`).

**Changing a value later:** update it in OpenBao, then **Hard Refresh** the app in Argo CD
(AVP only fetches values when it renders) and sync. The pod restarts on its own if Stakater
Reloader is installed. Otherwise run `kubectl -n mhacs-verify rollout restart deploy/waha`.

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

- **Plugin:** the Application renders through your argocd-vault-plugin **Config
  Management Plugin** (`spec.source.plugin.name: argocd-vault-plugin-kustomize`). Change the
  name to match your CMP. It has to run `kustomize build .` and pipe the output into
  `argocd-vault-plugin generate -`. If your existing AVP plugin only does Helm, add a
  kustomize variant. A typical sidecar `plugin.yaml`:
  ```yaml
  apiVersion: argoproj.io/v1alpha1
  kind: ConfigManagementPlugin
  metadata:
    name: argocd-vault-plugin-kustomize
  spec:
    generate:
      command: ["sh", "-c"]
      args: ["kustomize build . | argocd-vault-plugin generate -"]
  ```
- **Private repo:** first add the repo to Argo CD (UI → Settings → Repositories, or
  `argocd repo add https://github.com/itachi1706/MHACS-Verification-Checker-Tool.git
  --username <user> --password <fine-grained PAT with read-only Contents>`).
- Uses `project: default`. Change it if you restrict projects. The project must allow
  namespace `mhacs-verify`, and the cluster-scoped `Namespace` kind.
- The namespace (and the PVC, if you use `local-sessions`) is annotated
  `Prune=false,Delete=false`, so Argo CD never deletes the session data.
- `base/vmservicescrape.yaml` needs the VictoriaMetrics operator CRDs. See §10.
- If a sync fails with `<path:...>` still in a Secret, AVP couldn't read that path. Check
  the key exists in OpenBao and AVP's policy covers it.

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
bao kv put kv/k8s/mhacs-verify/waha-mtls \
  tls_crt=@certs/server.crt tls_key=@certs/server.key ca_crt=@certs/ca.crt
```

Hard Refresh and sync in Argo CD (the pod restarts through Reloader, or run
`kubectl -n mhacs-verify rollout restart deploy/waha`). Then update the client cert in SST
(`sst secret set ...`).

## 10. Metrics (VictoriaMetrics) / Grafana

`WAHA_PROMETHEUS_ENABLED=True` turns on WAHA's `/metrics`. The sidecar serves only that
path, on plain HTTP port **9090** (Service port `metrics`). The NetworkPolicy allows 9090
only from the `monitoring` namespace, where VMAgent runs.

- `base/vmservicescrape.yaml` is a native **VMServiceScrape**. victoria-metrics-k8s-stack's
  VMAgent selects all VMServiceScrapes by default (`selectAllByDefault: true`), so no label
  is needed.
  - If you've turned that off, add the label your VMAgent's `serviceScrapeSelector`
    expects.
  - (A Prometheus `ServiceMonitor` would also work through the operator's converter. The
    native resource just avoids depending on it.)
- In Grafana (VictoriaMetrics datasource) the metrics are prefixed `waha_`:
  `waha_up`, `waha_session_status`, `waha_session_activity_timestamp_seconds`,
  `waha_messages_total`, `waha_events_total`, `waha_http_requests_total`.
- Suggested alerts (VMRule): `waha_up == 0` for 5m; session not `WORKING` for 10m; pod
  restarts. The SES email alert from the app also covers a disconnected session.
- Check the scrape: VMAgent UI → *Targets* → `serviceScrape/mhacs-verify/waha`.
