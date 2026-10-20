# MHACS Verification Checker Tool — Feasibility & Plan

> Status: **exploratory / planning only**. No implementation yet.

## 1. Problem

During a production cut-over, a coordinator posts a long checklist message into the
"MHACS eServices" WhatsApp group. Each eService team copies the message, puts
✅ / ➖ / ❓ / ❌ / ⚠️ on the left of their own line, and reposts it. The coordinator
then has to read every repost to work out the current state.

Example of the message shape:

```
Hi eService Teams,

Please verify your eServices on Production now and let us know if your
integration is working. Please help acknowledge by putting a ✅ or ➖ (not
applicable) on the left of your eService.
...

SingPass:
✅ MHA-IROSES2-SINGPASS (ROS), POC: Chua Wei Yi
✅ CNB-GPC-ENOTIF, POC: Arthur Chuan
❓ SHARE-SP, POC: Houston/Arthur
...
```

The goal is a small web tool that builds this message from templates, sends it to the
group, reads the replies, keeps a single source of truth for the statuses, and lets admins
repost or close the verification.

## 2. Verdict: is it possible?

**Yes.** Every requirement can be built. The one real constraint is **how we talk to
WhatsApp**:

| Option | Can post into an *existing* group with people already in it? | Can read group replies? | Notes |
|---|---|---|---|
| **WhatsApp Business Cloud API (official, Meta)** | ❌ Not really. Meta's Groups API only covers groups the business creates itself, with a small participant cap, and members join by invite link. Our existing group can't be used. | Only in those business-created groups | Needs Meta Business verification, a dedicated number, and pre-approved templates for business-initiated messages. |
| **WAHA (WhatsApp HTTP API, self-hosted)** | ✅ Yes. It acts as a linked device on a normal WhatsApp account. | ✅ Yes, via webhooks (`message`, `message.any`, `message.edited`, `message.reaction`) | Unofficial (drives WhatsApp Web), so it's against WhatsApp ToS and the number could be banned. Fine for low volume. |
| Other unofficial libraries (Baileys, whatsapp-web.js) | ✅ | ✅ | WAHA wraps these engines (NOWEB/GOWS/WEBJS) behind a stable REST API and Docker image, so we'd just be rebuilding WAHA. |

**Recommendation: WAHA**, behind an internal adapter interface (`WhatsAppGateway`), so we can
swap in the official API or another channel (e.g. Teams, Telegram) later without touching
the core logic.

### Risks to accept or mitigate before going ahead

1. **ToS / ban risk.** Use a **dedicated SIM/number** for the bot, not anyone's personal number.
   Keep volume low (a handful of messages per verification, no bulk messaging).
2. **Organisational policy.** This looks like a government (MHA) context. Check whether
   an unofficial WhatsApp integration, and storing group messages on our own server, is
   allowed under the relevant IT and data-classification policies (e.g. IM8). **This is
   the most likely blocker, and it isn't a technical one.**
3. **Session lifetime.** A linked device can get logged out. If the phone is offline for
   about 14 days, WhatsApp unlinks it. Planned mitigation: a health check, plus an admin
   page that shows the WAHA QR code / pairing code so the session can be relinked.
4. **Parsing ambiguity.** People will reformat the text. Mitigation: match on the
   **service code**, never on line position, and let admins override.
5. **WhatsApp edit window.** A sent message can only be edited for about 15 minutes, so
   "updated status" is sent as a **new message** (optionally quoting the original), not
   an edit.

## 3. Feature breakdown (mapped to the requirements)

| # | Requirement | Design |
|---|---|---|
| R1 | Integrate with WhatsApp to craft and send template messages | WAHA `POST /api/sendText` to the group `chatId` (`...@g.us`). The message is rendered server-side from the template. |
| R2 | IP restriction to specific incoming IPs only | Allowlist at two layers: the reverse proxy (Caddy/Nginx `allow`/`deny`) and app middleware (CIDR allowlist from config, with `X-Forwarded-For` trusted only from the proxy). WAHA is **never exposed** and only talks to the app on the internal Docker network, protected by its API key. |
| R3 | Groups of services, each with services and a POC | `ServiceGroup` (e.g. "SingPass", "CorpPass") → `Service` (code, display name, POC text, order, active flag). CRUD UI. |
| R4 | Customisable opening and closing text | Each template has a `header` (intro), a `footer` (thank-you), and a `closing_message`. Placeholders such as `{{date}}`, `{{title}}`, `{{summary}}`. |
| R5 | Flow: choose template → edit top text → preview → send | A 4-step wizard. The preview is the exact rendered WhatsApp text, including WhatsApp's `*bold*` / `_italic_` formatting. |
| R6 | Bot reads replies and updates statuses (✅ ❌ ⚠️ ❓ ➖), ignoring unknown messages | Webhook → parser → status updates (see §5). Messages that match no service, or come from another chat, are ignored. |
| R7 | Admins can manually update and send a new updated message | Status grid in the UI: click a cell to change it. A "Send updated list" button renders the current state and sends it. |
| R8 | "Close verification" sends another customisable message | Closing sets the verification to `CLOSED`, sends the rendered `closing_message` (e.g. a summary of outstanding ❓/❌ items), and the parser stops accepting updates for it. |

## 4. Architecture

```
          Admin browser (allowlisted IPs only)
                     │ HTTPS
              ┌──────▼──────┐
              │ Caddy/Nginx │  IP allowlist, TLS
              └──────┬──────┘
                     │
              ┌──────▼─────────────────────┐        ┌────────────┐
              │  App (API + Web UI)        │◄──────►│ PostgreSQL │
              │  - templates / services    │        │ (or SQLite)│
              │  - verification engine     │        └────────────┘
              │  - message parser          │
              │  - WhatsAppGateway (WAHA)  │
              └──────▲──────────┬──────────┘
        webhook      │          │  REST (X-Api-Key)
     (internal only) │          ▼
              ┌──────┴────────────────┐
              │  WAHA (Docker)        │ ── linked device ──► WhatsApp
              │  internal network only│
              └───────────────────────┘
```

Proposed stack (open to change):
- **Backend:** TypeScript + Node (Fastify or NestJS), Prisma ORM. Python/FastAPI would work just as well.
- **Frontend:** React (Vite) or Next.js, with a simple component library.
- **DB:** PostgreSQL. SQLite is enough for a single-instance MVP.
- **Deploy:** `docker compose` with `proxy`, `app`, `db`, `waha`.
- **Auth:** the IP allowlist is not enough on its own, so add admin login too (local accounts or SSO/OIDC if available), with roles `admin` and `viewer`.

## 5. Reply parsing (the core logic)

1. A WAHA webhook arrives (`message` / `message.edited`). Verify the shared secret / HMAC.
2. Drop it unless `chatId` is the group of an **OPEN** verification. Drop messages sent by the bot itself (`fromMe`).
3. Split the body into lines. For each line:
   - Normalise: Unicode NFC, strip variation selectors (`U+FE0F`), collapse whitespace.
   - Find a **known service code** in the line (case-insensitive, word-boundary match,
     longest code first so `MHAICA-eRBD` isn't confused with a shorter code).
   - Read the **leading status token** before the code:
     `✅ ✔️ ☑️` → `OK`, `❌ ✖️` → `FAIL`, `⚠️` → `WARN`, `❓ ?` → `UNKNOWN`,
     `➖ - —` → `NA`. Anything else → ignore that line.
4. Only apply a line when its status **differs** from the current one, so a full repost
   that copies everyone else's unchanged statuses doesn't overwrite newer changes. Optional
   stricter mode: only accept a change if the sender is a mapped POC for that service.
5. Write a `StatusEvent` (service, old→new, sender, WhatsApp message id, raw line, time)
   for the audit trail.
6. Also optional: a **reaction** or a short reply like "✅" quoted on a single line, mapped
   via `quotedMsg`.
7. A message where nothing matches → ignored silently, as requested.

Conflict example: Team A reposts at 10:46 with only their line changed, but their copy
still shows Team B as ❓, while Team B already set ✅ at 10:45. Rule 4 keeps B at ✅
only if we compare against the **version the poster copied from**. A simple heuristic:
ignore a status that matches the *initial* default (❓/blank) when the current status
is already set. Admins can always override.

## 6. Data model (draft)

```
ServiceGroup(id, name, sort_order)
Service(id, group_id, code, display_name, poc, sort_order, active)
Template(id, name, chat_id, header, footer, closing_message,
         default_status, created_at, updated_at)
TemplateService(template_id, service_id, sort_order)   -- which services a template includes
Verification(id, template_id, title, header_override, status[DRAFT|OPEN|CLOSED],
             chat_id, opened_by, opened_at, closed_at)
VerificationItem(verification_id, service_id, status, updated_by, updated_at,
                 snapshot_code, snapshot_poc)            -- snapshot so later edits don't rewrite history
OutboundMessage(id, verification_id, kind[INITIAL|UPDATE|CLOSE], wa_message_id, body, sent_by, sent_at)
StatusEvent(id, verification_id, service_id, old, new, source[WHATSAPP|ADMIN],
            sender, wa_message_id, raw_line, created_at)
AdminUser(id, email, role, ...)
```

## 7. Admin screens

1. **Dashboard:** open verifications, WAHA session health (connected / QR needed).
2. **Services & groups:** CRUD, drag to reorder, POC editing.
3. **Templates:** header, footer, closing text, target group (picked from WAHA's group list), included services.
4. **New verification wizard:** template → edit header → preview → send.
5. **Live verification:** status grid that updates live (SSE/WebSocket), a feed of parsed changes with the raw message, manual override, "Send updated list", "Close verification".
6. **History / audit:** past verifications with exports (CSV).
7. **WhatsApp session:** QR / pairing code, logout, test message.

## 8. Phased delivery

| Phase | Scope | Exit criteria |
|---|---|---|
| **0 – Spike (1–2 days)** | Run WAHA in Docker, link a test number, send to a test group, capture webhook payloads, prototype the parser on real reposts. | A test-group message is sent, and replies parse correctly. **Policy check done.** |
| **1 – MVP** | Services/groups/templates CRUD, wizard, send, manual status grid, send update, close. No auto-parsing yet. | Usable end-to-end with manual updates. |
| **2 – Auto-parsing** | Webhook ingestion, parser, audit feed, live UI. | Real reposts update the grid with no admin input. |
| **3 – Hardening** | IP allowlist at both layers, admin auth/roles, webhook HMAC, backups, session health alerts, rate limiting. | Security review passed. |
| **4 – Nice-to-haves** | Reactions/quoted replies, a POC→sender phone mapping, scheduled reminders ("3 services still ❓"), CSV export, multiple channels. | — |

## 9. Open questions for the team

1. Is an unofficial WhatsApp integration (WAHA) acceptable under policy? If not, is a different channel (e.g. Teams, which we may already have) acceptable for the same workflow?
2. Do we have a dedicated number/SIM for the bot, and who owns the phone?
3. Should the bot send into the **existing** "MHACS eServices" group, or into a new group?
4. Hosting: on-prem / GCC / a cloud VM? Which IPs or CIDRs need to be allowlisted?
5. Should anyone in the group be able to update any service, or only the mapped POC?
6. When a service is missing from the list (per the message: "If any eService is not in this list…"), should a new code in a reply create a **pending suggestion** for an admin to approve?
7. Preferred stack: TypeScript or Python?
