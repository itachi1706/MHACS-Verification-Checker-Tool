# MHACS Verification Checker Tool: Feasibility & Plan

> Status: **planning only**. Nothing is built yet. Revision 2 adds the team's answers
> (see §9).

## 1. Problem

During a production cut-over, a coordinator posts a long checklist message into the
"MHACS eServices" WhatsApp group. Each eService team copies the latest list, puts
✅ / ➖ / ❓ / ❌ / ⚠️ on the left of their own line, and posts it again as a new message.
The coordinator then has to read every repost to work out the current state.

Message shape:

```
Hi eService Teams,

Please verify your eServices on Production now ... putting a ✅ or ➖ (not
applicable) on the left of your eService.
...

SingPass:
✅ MHA-IROSES2-SINGPASS (ROS), POC: Chua Wei Yi
✅ CNB-GPC-ENOTIF, POC: Arthur Chuan
❓ SHARE-SP, POC: Houston/Arthur
...
```

Goal: a web tool that builds this message from templates and sends it to the group. It
reads the replies and keeps the current status of each service in one place. Admins can
post an updated list or close the verification.

## 2. Verdict

**This can be built**, using **WAHA** (self-hosted WhatsApp HTTP API) linked to a dedicated
**WhatsApp Business app** number.

- The official WhatsApp Cloud API can't post into an existing group of external people,
  so WAHA is the only practical option here.
- The bot number being on the **WhatsApp Business app** is fine. WAHA connects as a
  *linked device*, just like WhatsApp Web, and this works for both normal and Business
  accounts. **Don't** move the number onto the Meta *Cloud API*. That takes it off the
  app and breaks the linked-device setup.
- Everything we send is a **new message**. We never edit. We do support **deleting our
  own messages**: WAHA `DELETE /api/{session}/chats/{chatId}/messages/{messageId}`.
  WhatsApp only allows "delete for everyone" for about 2 days after sending.
- The group is unofficial and isn't covered by any data-classification rules (confirmed by
  the team). The remaining risk is the usual one for unofficial integrations: WhatsApp
  could ban the number. Low volume and a dedicated number keep this risk small.

## 3. Hosting: Lambda on AWS, WAHA on DigitalOcean Kubernetes

WAHA keeps a **permanent WebSocket connection** to WhatsApp and stores its session files
on disk. Lambda is short-lived and stateless, so it can't host WAHA. WAHA runs on the
team's existing **DigitalOcean Kubernetes (DOKS)** cluster. Everything else stays
serverless on AWS.

| Component | Runs on |
|---|---|
| Web app (Next.js) | AWS Lambda + CloudFront (SST/OpenNext) |
| Webhook receiver (WAHA → app) | AWS Lambda, own function URL |
| Health check cron | AWS Lambda + EventBridge |
| App data | DynamoDB |
| Alerts | SES (SMTP/API) |
| **WAHA** | **DOKS**: a Deployment with 1 replica, a persistent volume, and an Ingress with TLS |

### 3.1 Docker image

No custom image is needed. We use the **official `devlikeapro/waha` image**, pinned to a
specific version tag (never `latest`), and configure it with env vars and a Secret. If
we need anything custom later, it would be a thin `FROM devlikeapro/waha:<ver>` layer.
What we deliver is **Kubernetes manifests** (or a Kustomize overlay) for the cluster.

### 3.2 Storage: Postgres (chosen) or a persistent volume

WAHA Core can store the session in **Postgres or MongoDB**
(`WHATSAPP_SESSIONS_POSTGRESQL_URL` / `WHATSAPP_SESSIONS_MONGO_URL`). Checked in the image:
with Postgres, the GOWS engine stores **both the login and its message/chat/group store**
in the database (otherwise it's SQLite on disk). **MySQL isn't supported**: the image
only has SQLite, Postgres and MongoDB backends, and GOWS only accepts SQLite or Postgres.
If the only existing DB is MySQL, use the PVC fallback. A new DO Postgres cluster (about
US$15/month) would break the budget.

| | Existing DO managed Postgres (chosen) | PVC (fallback) |
|---|---|---|
| Cost | US$0 (already paid) | About US$0.10/GiB/month |
| Backups | Included in the managed DB's daily backups and PITR | None. Losing the volume means a QR re-link and an empty history store |
| Pod scheduling | Stateless pod that restarts or moves nodes instantly | Pod is tied to a block volume, which has to detach and reattach on node upgrades |
| History catch-up (§3.7) | Message store survives pod or volume loss | Lost along with the volume |
| Dependencies | The bot is down if the DB is down. Uses about 10–20 connections. Needs `CREATEDB` or pre-created DBs | None beyond the cluster |

→ **Use the existing Postgres.** The PVC stays available as a Kustomize component
(`components/local-sessions`) to switch back with one line.

Details (from the image):
- WAHA creates the databases `waha_<WAHA_NAMESPACE>` and `waha_<namespace>_<session>`,
  i.e. `waha_mhacs` and `waha_mhacs_default`. It checks whether they exist first, so they
  can be pre-created if the user can't `CREATEDB`.
- Connect directly, not through PgBouncer (WAHA runs `CREATE DATABASE` and keeps its own
  pools).
- TLS is used but the server cert isn't verified. That's acceptable inside the DO VPC.
- Our own app data (verifications, statuses, audit) still lives in **DynamoDB**, next to
  the Lambdas.

### 3.3 Kubernetes shape

The manifests are in **`deploy/k8s/waha/`** (Kustomize base + overlays, plus an Argo CD
Application in `deploy/argocd/`). Setup steps are in `deploy/k8s/waha/README.md`. Summary:

- **Deployment `waha`**: 1 replica with `Recreate` strategy (one WhatsApp session can't be
  shared between pods).
  - Image `devlikeapro/waha:gows-2026.9.2` (Core, GOWS engine), with the session
    auto-started.
  - Dashboard and Swagger off. Runs as non-root.
  - Sidecar `mtls-proxy` (`nginxinc/nginx-unprivileged:1.30.6-alpine`, read-only root
    filesystem).
- **Session storage**: the existing DO managed Postgres (`WHATSAPP_SESSIONS_POSTGRESQL_URL`).
  Optional PVC component as a fallback.
- **Metrics**: `WAHA_PROMETHEUS_ENABLED`. The sidecar serves only `/metrics` on port 9090
  (monitoring namespace only), scraped by VictoriaMetrics via a `VMServiceScrape`.
- **Service `waha-mtls`**: port 9443 → the sidecar only. WAHA's port 3000 isn't in the Service.
- **NetworkPolicy**: inbound traffic only to 9443. Outbound is open (WhatsApp and the webhook
  Lambda have no fixed IPs).
- **Secrets, managed by Argo CD from OpenBao** (argocd-vault-plugin `<path:...>` placeholders,
  no values in git):
  - `waha-env`: `WAHA_API_KEY`, `WHATSAPP_HOOK_HMAC_KEY`, `WHATSAPP_HOOK_URL`,
    `WHATSAPP_SESSIONS_POSTGRESQL_URL`.
  - `waha-mtls`: server cert/key + CA.

**Checked against the actual image** (`gows-2026.9.2`, published 2026-10-02):
- The env var names in the manifests exist in the image.
- The API key is read from `WAHA_API_KEY` or `WHATSAPP_API_KEY`; the entrypoint hashes it
  with SHA-512.
- Session files default to `./.sessions` (`/app/.sessions`).
- Webhooks are signed with `X-Webhook-Hmac` (SHA-512 of the body), and also carry
  `X-Webhook-Timestamp` and `X-Webhook-Request-Id`. Only the body is signed, so the Lambda
  checks the `timestamp` field *inside* the signed body to reject replays, and dedupes by
  message id.

**WAHA Core vs Plus:** most former Plus features are now in Core. We checked the image:
the Core build only blocks *API-key management* (multiple keys) and image/voice/video
*status* posts. We need neither, so **Core (free) is enough**.

### 3.4 Securing WAHA without a NAT

Anyone who can call the WAHA API **controls the bot's WhatsApp account**, so it must be
locked down. Lambda has no fixed outgoing IP, and the team doesn't want a NAT. So we
lock it down **by identity instead of by IP**. That costs nothing, and the Lambdas run
**outside any VPC**.

**Chosen: three layers, all free and independent of the ingress controller**

The cluster runs **ingress-nginx** (retired) today and will move to **Cilium Gateway**.
Cilium's Gateway API does **not yet support** client-certificate validation
(GEP-91 / `GatewayFrontendClientCertificateValidation`): upstream PR cilium/cilium#48587
is still unmerged. So mTLS **can't depend on the edge**. It's handled **inside the WAHA
pod**, and the edge only does **TLS passthrough** by hostname (SNI). Both controllers
support passthrough, so the pod, the certificates and the Lambda code stay the same
through the migration. Only one routing object changes.

1. **mTLS sidecar** (`nginx-unprivileged`, pinned) in the WAHA pod:
   - It terminates TLS with a **server cert issued by our own private CA** (no Let's
     Encrypt or cert-manager needed, because only our Lambdas connect and they trust
     that CA).
   - It requires a **client cert** signed by the same CA (`ssl_verify_client on`).
   - It forwards only `/api/*` to WAHA on `127.0.0.1:3000`.
   - Requests without a valid client cert are rejected by nginx (HTTP 400) and never
     reach WAHA. Tested locally: no cert → 400, cert from another CA → 400, valid cert
     → forwarded, non-`/api` path → 404.
   - The Lambdas keep the CA cert, client cert and key in SST `Secret`s and pass them to
     an `undici` `Agent` (`ca`, `cert`, `key`).
2. **`WAHA_API_KEY`** on every request, with WAHA's dashboard and Swagger turned off.
3. **NetworkPolicy** (enforced by Cilium): only the sidecar port is reachable, and WAHA's
   own port is never exposed by the Service. Both containers run as non-root with
   `readOnlyRootFilesystem`, and the volume is the only writable path.

**Routing during each phase (the only part that changes):**

| | Today: ingress-nginx | Later: Cilium Gateway |
|---|---|---|
| Object | **TCP stream** on port 9443 via the controller's existing `--tcp-services-configmap` (Helm value `tcp: {"9443": "mhacs-verify/waha-mtls:9443"}`) | `TLSRoute` (Gateway API) on a `TLS` listener, port 9443, `mode: Passthrough`, `hostname: waha.<domain>` |
| Requirement | One Helm value. It adds port 9443 to the **existing** DO load balancer at no cost. `--enable-ssl-passthrough` is *not* needed (it would send all 443 traffic through an extra proxy). | TLSRoute is an *experimental-channel* CRD. Install the experimental Gateway API CRDs that match the Cilium version, and add the listener to the **existing shared Gateway** (a new Gateway creates a new DO LB, about US$12/month). |
| Fallback | `--enable-ssl-passthrough` + an Ingress, or the native `auth-tls-*` annotations | When Cilium ships GEP-91, mTLS *could* move to the edge, but nothing has to change |

**DNS:** just an `A`/`CNAME` record such as `waha.<your-route53-domain>` → the existing
load balancer IP. No Cloudflare needed. It's machine-to-machine only, so the name can
stay obscure.

**Extra cost: US$0.** It reuses the existing load balancer and uses a private CA (free).

**Certificate handling:** the CA key is generated once (offline, kept by the admin) and
never stored in the cluster. Server and client certs are valid for 1 year. A runbook and
a script (`scripts/certs.sh` using `openssl`) handle rotation. The health-check cron
warns by email 30 days before the client or server cert expires.

**Alternative (not used: no suitable Cloudflare domain; personal domains excluded): Cloudflare Tunnel.** This needs a
domain on Cloudflare. *Any* domain works, because only our Lambdas call this hostname
(e.g. a spare domain at about US$10/year ≈ US$0.85/month; the free plan is enough).
`cloudflared` runs in the cluster and connects out to Cloudflare, so WAHA needs no
Ingress or open port. Lambdas authenticate with a **Cloudflare Access service token**
(the `CF-Access-Client-Id/Secret` headers). Use this if a Cloudflare domain is available.
It could also put Cloudflare Access in front of the web app later.

**Considered and rejected:**
- *NAT + Elastic IP for an IP allowlist:* about US$3–5/month, and not wanted.
- *A queue relay (Lambda → SQS → relay pod polling → WAHA):* free and needs no inbound
  connections, but synchronous calls (sending a message and getting its id back, the QR,
  listing groups) become request/reply over queues. Too complex for what it adds.
- *Tailscale inside Lambda:* possible, but awkward to run in Lambda.

**The other direction (WAHA → webhook Lambda):** DOKS node IPs change, so the webhook
Lambda checks **WAHA's HMAC signature** (`X-Webhook-Hmac`, SHA-512) and rejects old
timestamps.

**Watch out:** don't create a *new* `LoadBalancer` Service for WAHA. A DigitalOcean load
balancer costs **about US$12/month**. Reuse the cluster's existing ingress controller and
load balancer.

### 3.5 Networking

```
 Admin browser ──HTTPS──► CloudFront ──► Next.js Lambda ─┐ (no VPC)
  (IP allowlist + login)                                  │ mTLS client cert + X-Api-Key
                                                          ▼
        DOKS edge (TLS passthrough by SNI) ──► WAHA pod [mTLS sidecar → WAHA] → DO Postgres
                                                                           │    ▲
 WhatsApp ◄──────────────────────── linked device ─────────────────────────┘    │
                                                                                │
 Webhook Lambda ◄──── HTTPS, HMAC-signed (message, session.status) ─────────────┘
       │
       └──► DynamoDB      Health-check cron Lambda ──► WAHA /api/sessions ──► SES alert
```

No VPC, NAT or VPC endpoints. The Lambdas reach DynamoDB, SES and WAHA over the public
AWS and HTTPS endpoints.

### 3.6 Why not ECS (or EC2) for WAHA? Cost comparison

ap-southeast-1 list prices (approximate), 24/7 for about 730 hours/month:

| Option | Compute | Public IPv4 (US$0.005/h) | Storage | **≈ Monthly** |
|---|---|---|---|---|
| **DOKS (existing cluster)** | spare capacity | uses the existing LB | existing Postgres, US$0 | **≈ US$0** |
| Fargate, 0.25 vCPU / 0.5 GB, ARM, on-demand | ≈ US$7 | ≈ US$3.65 | EFS ≈ US$0.30 | ≈ US$11 |
| Fargate Spot, ARM | ≈ US$2–3 (can be interrupted, then reconnects) | ≈ US$3.65 | EFS ≈ US$0.30 | ≈ US$6–7 |
| EC2 t4g.nano + Docker | ≈ US$3.1 | ≈ US$3.65 | EBS 2 GB ≈ US$0.20 | ≈ US$7 |
| EC2 inside AWS free-tier credits | US$0 while credits last | counts against credits | — | US$0, temporary |

On AWS, WAHA needs outbound internet. Without a NAT, that means a **public IPv4 address,
which alone costs about US$3.65/month**, so no always-on AWS option comes in under US$5.
(An IPv6-only task would avoid that charge, but it's newer and riskier. Not worth it here.)
Inside a VPC on AWS, the Lambdas could reach WAHA privately, but the Lambdas that also
need SES would need a NAT or an SES interface endpoint (about US$7+/month), which brings
the cost straight back.

→ **Keep WAHA on DOKS.** It's the only option that is free or nearly free.

### 3.7 WAHA Core features in the first version

Checked in the `gows-2026.9.2` Core image: the GOWS engine implements these, and Core no
longer restricts them. **All of the following are in the first version** (decided by
the team):

| WAHA feature | How we use it |
|---|---|
| **Fetch chat history** (`GET /api/{session}/chats/{chatId}/messages`) | **Catch-up / reconcile**: after a WAHA restart, a webhook failure or Lambda errors, re-read the group's messages since the last processed one and run them through the parser (deduped by message id). Triggered when `session.status` turns `WORKING`, and by the health-check cron. |
| **Reactions** (`PUT /api/reaction`) | React **👍** to a member's message once its changes are applied. Messages with nothing to apply get no reaction. |
| **Groups + participants** (`GET /api/{session}/groups`, `.../participants`) | Choose the target group from a list in the template editor. Show the group's members. Map participant numbers to POCs (the basis for "only the POC can update" later). |
| **Reply / quote** (`reply_to` on `sendText`) | Update, reminder and closing messages quote the original checklist. |
| **Mentions** (`mentions` on `sendText`) | A **"Send reminder"** button posts the outstanding services and **@mentions** their POCs (using the POC→number mapping). POCs without a mapped number are listed by name. |
| **Prometheus metrics** (`WAHA_PROMETHEUS_ENABLED`) | Scraped by the team's VictoriaMetrics (victoria-metrics-k8s-stack, `monitoring` namespace) via `VMServiceScrape`. Grafana dashboards and alerts on `waha_session_status` and `waha_up`. |

**Kept in view for later:** multiple sessions (a separate test number), polls, events,
labels. **Not used:** Chatwoot/MCP apps, S3/Postgres media storage.

Still Plus-only in this build: **API key management** (multiple keys) and image/voice/video
**status** posts. We need neither. The spike checks each row on the real number before we
build on it.

## 4. Restricting access to the web app

**Cloudflare Access when DNS stays in Route 53:** Access only works when traffic goes
through Cloudflare, which needs the hostname in a Cloudflare zone. With DNS in Route 53:

- **Partial (CNAME) setup** keeps DNS in Route 53, but needs a **Business plan or higher**.
- **Delegating only a subdomain** (e.g. NS records for `verify.example.gov.sg` → Cloudflare)
  is an **Enterprise** feature.
- A **separate domain** you own that's already on Cloudflare (free plan) would work:
  Cloudflare in front of the CloudFront origin. But the URL wouldn't be on the Route 53 domain.

→ Unless one of these fits, **use the IP allowlist** (plus an app login). Planned approach:

1. **IP allowlist, set from an env var** (`ALLOWED_CIDRS=1.2.3.4/32,5.6.7.0/24`):
   - Primary: a **CloudFront Function** on viewer-request checks the client IP against the
     list (very cheap, applied at the edge, and the IP can't be spoofed). SST puts the
     list into the function at deploy time.
   - Alternative: **AWS WAF IP set** on the CloudFront distribution (about US$6+/month,
     can be changed without a redeploy).
   - Backup check in Next.js middleware using `CloudFront-Viewer-Address`.
     **Never trust `X-Forwarded-For`.**
2. **App login on top of that:** a simple admin login (Auth.js with credentials, or a magic
   link via SES), so a shared office IP isn't enough on its own. We can switch to Cloudflare
   Access later without code changes, because the app will accept either.

## 5. Reply parsing (core logic)

The flow, as confirmed by the team: we send the original message (and any update) as new
messages. Users copy the list, add their marks, and send it as a new message. We parse it
and update our stored statuses.

1. WAHA sends a webhook (`message`). Check the HMAC. **Ignore it** if it's from another
   chat, if the chat has no **OPEN** verification, or if it's `fromMe` (our own message).
   Use the WhatsApp message id to **skip duplicates**, because webhooks can be retried.
2. Split the message into lines and normalise each one: Unicode NFC, remove the
   `U+FE0F` emoji variation selector, collapse spaces.
3. For each line, read the **leading status mark**:

   | Mark(s) | Status |
   |---|---|
   | ✅ ✔ ☑ | `OK` |
   | ❌ ✖ | `FAIL` |
   | ⚠ | `WARN` |
   | ❓ ❔ `?` | `PENDING` (the default) |
   | ➖ `-` `—` | `NA` |

   A line without a mark is ignored.
4. Find the **service code** after the mark. Match it against known codes in the
   verification (case-insensitive, whole-word, **longest code first**).
5. **What to apply:** a repost is a full copy of the list, so most of its lines are other
   teams' older statuses. The rules:
   - Apply a line only if its status **differs** from the one we store.
   - **Never go back to `PENDING`.** If we already have ✅ and a repost shows ❓, it's an
     out-of-date copy. Ignore it.
   - Any other change (✅→❌, ❌→✅, →⚠, →➖) applies, and the most recent message wins.
6. **Unknown services:** a line in the shape `<mark> CODE[ (alias)], POC: name` whose code
   we don't know creates a **pending service suggestion** (code, POC, the group header it
   appeared under, sender, raw line). An admin approves it in the web app. Approval adds
   it to the service catalog and, optionally, to the current verification. Repeated
   sightings are merged by code.
7. Anything else (chat, "noted", stickers) is **ignored**.
8. Each change is saved as a `StatusEvent` (old→new, sender name/number, message id, raw
   line, time), so admins can see where every status came from and undo it.

The parser is a **pure function** with tests run against real reposts from the test group.

## 6. Notifications (re-scan QR / WAHA down)

- WAHA sends a webhook (`session.status`) on every session change (`WORKING`,
  `SCAN_QR_CODE`, `FAILED`, `STOPPED`). Anything other than `WORKING` → **notify the
  admins**.
- The alert can't go over WhatsApp, because the bot's own session is the thing that's
  down. Alerts go out by **email via SES** (SMTP or API; confirmed by the team).
- The **cron health check** (every 5–10 minutes) calls WAHA `GET /api/sessions/default`.
  It catches the case where WAHA itself has crashed and so can't send a webhook. Alerts
  are de-duplicated, so admins get one message per incident.
- The web app has a **"WhatsApp session" page** showing the live QR (`/api/{session}/auth/qr`)
  and a **pairing code** option (`/api/{session}/auth/request-code`). With the pairing
  code, the phone owner just types an 8-character code on the phone and doesn't have to
  scan anything.

## 7. Features (final scope)

| # | Feature | Notes |
|---|---|---|
| F1 | Service groups & services (code, alias, POC, order, active) | CRUD and reordering |
| F2 | Templates: target group, header, footer, update header, closing message, included services | Placeholders such as `{{title}}`, `{{date}}`, `{{outstanding}}`, `{{summary}}`. The target group is chosen from WAHA's group list. |
| F3 | New verification wizard: template → edit header → **preview** → send | The preview is the exact WhatsApp text |
| F4 | Live status grid | Polls every few seconds. Lambda doesn't keep connections open, so polling is simpler than SSE/WebSockets. |
| F5 | Auto-parse replies | §5 |
| F6 | Manual override and "Send updated list" | Sends a new message built from the current state |
| F7 | Pending service suggestions | §5.6 |
| F8 | Close verification → closing message | Then parsing stops for that verification |
| F9 | Delete one of our sent messages | From the list of sent messages in the verification view |
| F10 | Session health and QR alerts | §6 |
| F11 | Access control | §4 |
| F12 | Catch-up from chat history | §3.7. Runs on WAHA reconnect (`session.status` → `WORKING`) and on the health-check cron |
| F13 | 👍 reaction on applied updates | §3.7 |
| F14 | Group picker + participant list | §3.7 |
| F15 | Updates/closing quote the original message | §3.7 |
| F16 | POC→phone mapping + "Send reminder" with @mentions | §3.7. Numbers picked from the group's participant list |
| F17 | Metrics (VictoriaMetrics) + Grafana | §3.7, `deploy/k8s/waha/README.md` §10 |

## 8. Data model (DynamoDB, single table with ElectroDB)

| Entity | Key (PK / SK) | Fields |
|---|---|---|
| ServiceGroup | `GROUP` / `GROUP#<id>` | name, order |
| Service | `SERVICE` / `SERVICE#<id>` | groupId, code, alias, poc, order, active |
| Template | `TEMPLATE` / `TEMPLATE#<id>` | name, chatId, header, footer, updateHeader, closingMessage, serviceIds[] |
| Verification | `VERIF#<id>` / `META` | templateId, title, header, status (DRAFT/OPEN/CLOSED), chatId, openedBy, openedAt, closedAt |
| VerificationItem | `VERIF#<id>` / `ITEM#<serviceId>` | snapshot of code, POC and group; status; updatedBy; updatedAt |
| OutboundMessage | `VERIF#<id>` / `OUT#<ts>` | kind (INITIAL/UPDATE/CLOSE), waMessageId, body, sentBy, deleted |
| StatusEvent | `VERIF#<id>` / `EVT#<ts>#<n>` | serviceId, old, new, source (WHATSAPP/ADMIN), sender, waMessageId, rawLine |
| Suggestion | `SUGGEST` / `SUGGEST#<code>` | poc, groupHint, seenCount, firstSeen, raw, status |
| Index: open verification by chat | GSI1: `CHAT#<chatId>` / `OPEN` | Used by the webhook to look up the verification fast |
| Processed message (dedupe) | `MSG#<waId>` / `MSG` | TTL of 7 days |

Postgres (e.g. Neon) with Drizzle would also work if we'd rather use SQL. Only the data
layer would change.

## 9. Decisions log (from the team)

| Topic | Decision |
|---|---|
| Channel | WhatsApp is required, because external parties are in the group |
| Bot account | Dedicated spare number on the **WhatsApp Business app** |
| Data classification | Not applicable (unofficial group) |
| Group | A new test group with testers first, then the existing MHACS eServices group |
| Editing messages | Never. Original and updates are sent as new messages. Deleting our own messages is supported. |
| Who can update | Anyone in the group, for now |
| Unknown services | Pending suggestion for an admin to approve in the web app |
| Hosting | AWS: SST + OpenNext on Lambda. WAHA on the existing **DigitalOcean Kubernetes** cluster, using the official image plus manifests (see §3). |
| WAHA storage | Existing DO managed **Postgres** (confirmed available; MySQL isn't supported by WAHA). Sessions + GOWS store. PVC kept as a fallback component (see §3.2). |
| First-version extras | History catch-up, 👍 reactions, group picker, quoted replies, @mention reminders, Prometheus metrics (see §3.7) |
| Kept for later | Multiple sessions, polls, events, labels |
| WAHA access | No NAT, no Cloudflare. **mTLS handled by a sidecar in the WAHA pod** (private CA) + API key + NetworkPolicy. The edge only does TLS passthrough (ingress-nginx now, Cilium `TLSRoute` later). Webhooks verified by HMAC. |
| Budget | Free, or under US$5/month. Not for public use. |
| Alerts | Email via SES |
| Cluster secrets | OpenBao, filled into the manifests by argocd-vault-plugin at render time |
| Access | Cloudflare Access if feasible (see §4), otherwise an IP allowlist from env vars, plus app login |
| Language | TypeScript throughout. WAHA is a REST API, so Python adds nothing. TS types come from WAHA's OpenAPI spec. |

## 10. Repository layout (proposed)

```
/                       SST v3 monorepo (pnpm workspaces)
├─ sst.config.ts        Dynamo, Nextjs, Functions, Cron, SES, Secrets (no VPC)
├─ deploy/k8s/waha/     Kustomize base: Namespace, Deployment (WAHA + mTLS/metrics sidecar), Service, NetworkPolicy,
│                        VMServiceScrape; components/local-sessions (PVC fallback);
│                        overlays: ingress-nginx (TCP 9443), cilium-gateway (TLSRoute)
├─ deploy/argocd/       Argo CD Application
├─ scripts/certs.sh     private CA / server / client cert generation + rotation
├─ packages/
│  ├─ core/             domain logic: parser, renderer, entities, WAHA client (pure TS + tests)
│  ├─ web/              Next.js admin app (OpenNext)
│  └─ functions/        webhook handler, health-check cron
└─ docs/PLAN.md
```

## 11. Phased delivery

| Phase | Scope | Exit criteria |
|---|---|---|
| **0: Spike** | Deploy `deploy/k8s/waha` to DOKS via Argo CD and link the Business number. Send to the test group. Record real webhook payloads and reposts. Confirm WAHA runs fine as non-root (uid 1000) with Postgres storage. Check the §3.7 features on the real number. Confirm the Prometheus scrape works. | Sending, receiving, deleting and session-status events work through the mTLS endpoint |
| **1: Foundations** | WAHA + mTLS sidecar deployed to DOKS (Postgres storage, passthrough route, NetworkPolicy, API key, metrics). Private CA and server/client certs. SST infra (DynamoDB, Next.js, Secrets). Web app IP allowlist. Admin login. | The admin app is reachable only from allowed IPs. WAHA rejects requests without the client cert. Pod restarts don't log the bot out. |
| **2: MVP sending** | Services, groups and templates CRUD. Group picker. POC→number mapping. Wizard, preview, send. Manual grid, send update (quoted), reminder with @mentions, close, delete message. | A full verification can be run by hand |
| **3: Auto-parsing** | Webhook, parser (with tests from real reposts), 👍 reactions, history catch-up, audit feed, suggestions | Reposts in the test group update the grid by themselves |
| **4: Ops** | Session alerts (SES), health cron, QR/pairing page, backups (DynamoDB PITR) | A forced logout produces an email within 10 minutes |
| **5: Go-live** | Switch the template's target to the real group | — |

Rough added running cost: WAHA uses spare capacity on the existing DOKS cluster, plus about
US$0 for storage (the existing managed Postgres). Lambda, DynamoDB, CloudFront and SES are within or about at free-tier
levels at this volume. **Total about US$0/month.**

## 12. Future enhancements

- Restrict updates for a service to its mapped POC(s), matched by sender phone number.
- Scheduled reminders (the manual "Send reminder" button is in the first version).
- Multiple WAHA sessions (e.g. a separate test number).
- Accept quoted replies and emoji reactions as status updates.
- CSV/PDF export of a closed verification.
- Cloudflare Access, if a suitable Cloudflare zone becomes available.

## 13. Open questions (round 3)

1. **ingress-nginx Service annotations:** is PROXY protocol enabled on the DO load balancer?
   Is `do-loadbalancer-protocol` set? This decides the exact `tcp:` value (see the deploy README).
2. ~~Secrets in the cluster~~: OpenBao + argocd-vault-plugin (paths in `deploy/k8s/waha/README.md` §2).
3. **Repo visibility:** is the repo private? Argo CD then needs a read-only token.
4. **WAHA hostname:** which Route 53 subdomain (e.g. `waha.<domain>`)?
5. **Cluster capacity and architecture:** WAHA needs about 256–768 MiB RAM. Are the nodes
   amd64? (`gows-*` is amd64; `gows-arm-*` exists for arm64.)
6. **Phone:** who holds the bot phone? WhatsApp unlinks devices if the phone is offline for
   about 14 days.
7. **SES:** which region? Will alerts go only to a few verified admin addresses (SES sandbox
   is fine), or do we need SES production access?
8. **Web app login:** who are the admins, and how should they sign in (email magic link via
   SES, or Google/Microsoft SSO)?
9. **One open verification per group at a time?** (Assumed yes.)
10. ~~Backups~~: covered by the managed Postgres backups.
11. **Postgres:** can the `waha` user have `CREATEDB`, or will you pre-create the two
    databases? Is there room for about 10–20 more connections on the DB plan?
12. ~~Prometheus~~: victoria-metrics-k8s-stack in `monitoring`, so we use a `VMServiceScrape`.
13. ~~Postgres or MySQL~~: the team has an existing DO managed Postgres, so we use it.

