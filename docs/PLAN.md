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
         nginx.ingress.kubernetes.io/whitelist-source-range: <Lambda NAT EIP>/32
```

The env var names above follow WAHA's docs. We'll check them against the pinned version
during the spike.

### 3.4 Does WAHA need restrictions? **Yes, it does.**

Anyone who can call the WAHA API **controls the bot's WhatsApp account**. They can read
all its chats and groups, send messages as the bot, and log the session out. So:

1. **Always (no extra cost):**
   - TLS on the Ingress.
   - A long random **`WAHA_API_KEY`**, so every call without it is rejected.
   - WAHA's own dashboard and Swagger turned off.
2. **Recommended: IP allowlist on the Ingress** so only our Lambdas can reach it. The
   catch is that **Lambda has no fixed outgoing IP** by default. Getting one means putting
   the Lambdas that call WAHA in a VPC behind a NAT with an Elastic IP. SST
   `Vpc({ nat: "ec2" })` does this for about US$3–5/month. The NAT's Elastic IP is the one
   address to allowlist on the DOKS Ingress.
   - Without the NAT, the protection is TLS plus the API key. That's acceptable for a
     start, but adding the allowlist later is strongly recommended.

**The other direction (WAHA → webhook Lambda):** DOKS sends traffic out from the
**node IPs**, which change when the node pool is recycled or upgraded. So the webhook
Lambda checks **WAHA's HMAC signature** instead of an IP. Allowlisting node IPs there
would be optional and fragile.

### 3.5 Networking

```
 Admin browser ──HTTPS──► CloudFront ──► Next.js Lambda ─┐
  (IP allowlist + login)                                  │ (VPC + NAT EIP, optional)
                                                          ▼
                              DOKS Ingress (TLS, allowlist: NAT EIP) ──► WAHA pod + PVC
                                                                           │    ▲
 WhatsApp ◄──────────────────────── linked device ─────────────────────────┘    │
                                                                                │
 Webhook Lambda ◄──── HTTPS, HMAC-signed (message, session.status) ─────────────┘
       │
       └──► DynamoDB      Health-check cron Lambda ──► WAHA /api/sessions ──► SES alert
```

If the Lambdas run inside a VPC, add a free **DynamoDB gateway endpoint**. SES goes out
through the NAT.

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
| WAHA access | TLS + API key always. Ingress allowlist set to the Lambda NAT Elastic IP (recommended). Webhooks verified by HMAC. |
| Alerts | Email via SES |
| Access | Cloudflare Access if feasible (see §4), otherwise an IP allowlist from env vars, plus app login |
| Language | TypeScript throughout. WAHA is a REST API, so Python adds nothing. TS types come from WAHA's OpenAPI spec. |

## 10. Repository layout (proposed)

```
/                       SST v3 monorepo (pnpm workspaces)
├─ sst.config.ts        Vpc (+NAT EIP), Dynamo, Nextjs, Functions, Cron, SES
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
| **1: Foundations** | WAHA manifests deployed to DOKS (PVC, Ingress, TLS, API key). SST infra (VPC + NAT EIP, DynamoDB, Next.js). IP allowlists on both sides. Admin login. | The admin app is reachable only from allowed IPs. WAHA is reachable only from the NAT EIP. Pod restarts don't log the bot out. |
| **2: MVP sending** | Services, groups and templates CRUD. Wizard, preview, send. Manual grid, send update, close, delete message. | A full verification can be run by hand |
| **3: Auto-parsing** | Webhook, parser (with tests from real reposts), audit feed, suggestions | Reposts in the test group update the grid by themselves |
| **4: Ops** | Session alerts (SES), health cron, QR/pairing page, backups (DynamoDB PITR) | A forced logout produces an email within 10 minutes |
| **5: Go-live** | Switch the template's target to the real group | — |

Rough added running cost: WAHA uses spare capacity on the existing DOKS cluster, plus about
US$0.20 for the PVC. The optional NAT instance with a fixed Elastic IP is about US$3–5.
Lambda, DynamoDB, CloudFront and SES are about free at this volume. **Total about
US$0–5/month.**

## 12. Future enhancements

- Restrict updates for a service to its mapped POC(s), matched by sender phone number.
- Reminders ("3 services still ❓"), sent automatically or by an admin with one click.
- React to the sender's message with 👍 once their changes are applied.
- Accept quoted replies and emoji reactions as status updates.
- CSV/PDF export of a closed verification.
- Cloudflare Access, if a suitable Cloudflare zone becomes available.
