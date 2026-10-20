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

### 3.2 Storage: does WAHA need a database?

**No separate database. It does need a persistent volume.**

- WAHA *Core* (free) stores the WhatsApp session (keys and login state) as **files on
  disk**. GOWS/NOWEB keep a small local store in the same folder. Without a persistent
  volume, every pod restart logs the bot out and needs a new QR scan.
- → **PVC of 1–2 GiB** (`ReadWriteOnce`, `do-block-storage`), mounted at the sessions path
  (`/app/.sessions`). Add `/app/.media` only if we ever handle media.
- Saving sessions to Postgres/MongoDB is a WAHA *Plus* (paid) feature. We don't need it.
- Our own app data (verifications, statuses, audit) lives in **DynamoDB**, not in WAHA.
- DO block storage costs about US$0.10/GiB/month, so **about US$0.20/month**.

### 3.3 Kubernetes shape

```yaml
# Deployment: waha (namespace: mhacs-verify)
replicas: 1                 # exactly one; two pods would fight over the same WhatsApp session
strategy: { type: Recreate } # old pod stops before the new one starts (RWO volume, single session)
image: devlikeapro/waha:<pinned-version>
env:
  WHATSAPP_DEFAULT_ENGINE: GOWS       # or NOWEB; no Chromium, ~200–400 MB RAM
  WAHA_API_KEY:          <from Secret>   # required on every API call (X-Api-Key)
  WHATSAPP_HOOK_URL:     https://<webhook-lambda-url>/waha
  WHATSAPP_HOOK_EVENTS:  message,session.status
  WHATSAPP_HOOK_HMAC_KEY: <from Secret>  # webhook body signed, Lambda verifies
  WAHA_DASHBOARD_ENABLED: "false"     # admin UI lives in our web app instead
  WHATSAPP_SWAGGER_ENABLED: "false"
volumeMounts: /app/.sessions -> PVC waha-sessions (1Gi)
resources: requests 100m / 384Mi, limits 500m / 768Mi
probes: GET /ping  (liveness/readiness)
---
Service: ClusterIP :3000
Ingress: waha.<domain> -> Service, TLS via cert-manager,
         client-certificate (mTLS) required, path /api only; reuse the existing ingress/LB
```

The env var names above follow WAHA's docs. We'll check them against the pinned version
during the spike.

### 3.4 Securing WAHA without a NAT

Anyone who can call the WAHA API **controls the bot's WhatsApp account**, so it must be
locked down. Lambda has no fixed outgoing IP, and the team doesn't want a NAT. So we
lock it down **by identity instead of by IP**. That costs nothing, and the Lambdas run
**outside any VPC**.

**Chosen: three layers, all free**

1. **TLS** on the Ingress (cert-manager + Let's Encrypt).
2. **Mutual TLS (client certificate).** The Ingress rejects any connection that doesn't
   present a client certificate signed by our own private CA. This happens before a
   request reaches WAHA, so scanners and bots never see it. The Lambdas load the client
   cert and key from an SST `Secret` and pass them to an `undici` `Agent`.
   - ingress-nginx: `nginx.ingress.kubernetes.io/auth-tls-secret` +
     `auth-tls-verify-client: "on"`. ingress-nginx was retired in March 2026, so on a
     current cluster use whatever controller is installed. Traefik (`TLSOption`
     `clientAuth`) and Envoy Gateway / Gateway API (`ClientTrafficPolicy`) both support
     this.
3. **`WAHA_API_KEY`** on every request, with WAHA's dashboard and Swagger turned off.

Also: only expose `/api/*` through the Ingress. WAHA runs as non-root with no extra
privileges, and has a NetworkPolicy limiting what it can reach.

**Alternative with no inbound connections at all: Cloudflare Tunnel.** This needs a
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
                              DOKS Ingress (TLS, client-cert required) ──► WAHA pod + PVC
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
| **DOKS (existing cluster)** | spare capacity | uses the existing LB | PVC ≈ US$0.20 | **≈ US$0.20** |
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
| WAHA storage | No database. One 1–2 GiB PVC for session files (see §3.2). |
| WAHA access | No NAT. TLS + **mTLS client cert** + API key (free). Cloudflare Tunnel + Access service token if a Cloudflare domain is available. Webhooks verified by HMAC. |
| Budget | Free, or under US$5/month. Not for public use. |
| Alerts | Email via SES |
| Access | Cloudflare Access if feasible (see §4), otherwise an IP allowlist from env vars, plus app login |
| Language | TypeScript throughout. WAHA is a REST API, so Python adds nothing. TS types come from WAHA's OpenAPI spec. |

## 10. Repository layout (proposed)

```
/                       SST v3 monorepo (pnpm workspaces)
├─ sst.config.ts        Dynamo, Nextjs, Functions, Cron, SES, Secrets (no VPC)
├─ deploy/k8s/waha/     Namespace, Secret (template), PVC, Deployment, Service, Ingress (Kustomize)
├─ packages/
│  ├─ core/             domain logic: parser, renderer, entities, WAHA client (pure TS + tests)
│  ├─ web/              Next.js admin app (OpenNext)
│  └─ functions/        webhook handler, health-check cron
└─ docs/PLAN.md
```

## 11. Phased delivery

| Phase | Scope | Exit criteria |
|---|---|---|
| **0: Spike** | Run WAHA locally in Docker and link the Business number. Send to the test group. Record real webhook payloads and reposts. Choose the engine (**GOWS** or **NOWEB**: no Chromium, low memory) and check the needed features work in the free *Core* tier (one session is enough). | Sending, receiving, deleting and session-status events all work |
| **1: Foundations** | WAHA manifests deployed to DOKS (PVC, Ingress with TLS + mTLS, API key). Private CA and client cert. SST infra (DynamoDB, Next.js, Secrets). Web app IP allowlist. Admin login. | The admin app is reachable only from allowed IPs. WAHA rejects requests without the client cert. Pod restarts don't log the bot out. |
| **2: MVP sending** | Services, groups and templates CRUD. Wizard, preview, send. Manual grid, send update, close, delete message. | A full verification can be run by hand |
| **3: Auto-parsing** | Webhook, parser (with tests from real reposts), audit feed, suggestions | Reposts in the test group update the grid by themselves |
| **4: Ops** | Session alerts (SES), health cron, QR/pairing page, backups (DynamoDB PITR) | A forced logout produces an email within 10 minutes |
| **5: Go-live** | Switch the template's target to the real group | — |

Rough added running cost: WAHA uses spare capacity on the existing DOKS cluster, plus about
US$0.20 for the PVC (plus about US$0.85 if a spare Cloudflare domain is bought for the
Tunnel option). Lambda, DynamoDB, CloudFront and SES are within or about at free-tier
levels at this volume. **Total about US$0.20–1/month.**

## 12. Future enhancements

- Restrict updates for a service to its mapped POC(s), matched by sender phone number.
- Reminders ("3 services still ❓"), sent automatically or by an admin with one click.
- React to the sender's message with 👍 once their changes are applied.
- Accept quoted replies and emoji reactions as status updates.
- CSV/PDF export of a closed verification.
- Cloudflare Access, if a suitable Cloudflare zone becomes available.
