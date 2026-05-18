# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## User Context
The developer is new to terminal/CLI workflows. Always provide full copy-paste commands when pushing updates, and assume the repo lives at `~/sf-visualizer` on the user's machine.

## Repo Layout

npm workspaces monorepo (root `package.json` declares the four workspaces). All are TypeScript, ESM (`"type": "module"`), and share the root `tsconfig.json`.

- `server/` — Express API on port 3001. Handles Salesforce OAuth, proxies SOQL/Tooling/Metadata calls via `jsforce`, calls Anthropic for AI explanations, and acts as a client to Salesforce's Hosted MCP server.
- `client/` — Vite + React 18 + Tailwind v4 frontend on port 5173. Dev server proxies `/auth` and `/api` to `http://localhost:3001` (see `client/vite.config.ts`). Path alias `@/*` → `client/src/*`.
- `mcp-server/` — Standalone stdio MCP server intended to be wired into Claude Desktop. Same `jsforce` tools as the web server, but exposed via the MCP protocol. Independent auth (token file).
- `slack-bot/` — Agentic Slack standup bot deployed to Vercel (separate deploy from the local SF Visualizer). HTTP-mode Bolt receiver, Vercel Cron, Vercel Postgres. See "Slack standup bot" section below.

## Common Commands

Run both servers from repo root:
```
npm run dev          # concurrently runs server + client
npm run build        # builds client then server
```

Per workspace:
```
npm run dev -w server          # tsx watch src/index.ts (port 3001)
npm run dev -w client          # vite (port 5173)
npm run dev -w mcp-server      # one-shot tsx (stdio)
npm run build -w server        # tsc → server/dist
npm run build -w client        # tsc -b && vite build
npm run start -w server        # node dist/index.js
```

No test or lint scripts are configured anywhere in this repo — don't fabricate them.

### After Pushing Changes
Tell the user to run, in order:
```
cd ~/sf-visualizer
git pull
```
Terminal 1 (backend):
```
cd ~/sf-visualizer/server
npx tsx watch src/index.ts
```
Terminal 2 (frontend):
```
cd ~/sf-visualizer/client
npx vite
```
Then refresh `http://localhost:5173`. Remind them to `Ctrl+C` each terminal before restarting.

### Editing `.env`
The server reads `.env` from the **repo root** (not `server/`), via `path.resolve(__dirname, "../../.env")` in `server/src/config.ts`. Tell the user:
```
open -a TextEdit ~/sf-visualizer/.env
```
Save with Cmd+S. See `.env.example` for the full set of keys (three OAuth credential pairs: the main Salesforce Connected App, an optional sandbox app, and a separate External Client App for the `mcp_api` scope used by Salesforce's Hosted MCP).

## Architecture

### Two parallel OAuth flows on the server
1. **Main Salesforce login** (`/auth/login`, `/auth/callback`) — PKCE flow against `login.salesforce.com` or `test.salesforce.com`. Scope: `api refresh_token`. Stores `req.session.sf` with `accessToken`, `refreshToken`, `instanceUrl`, identity info, and `environment`.
2. **Hosted MCP login** (`/auth/mcp-login`, `/auth/mcp-callback`) — second PKCE flow against the user's own org (`<instanceUrl>/services/oauth2/authorize`) using **External Client App** credentials with scope `mcp_api`. Stores only `req.session.mcpToken`. Required because Salesforce's Hosted MCP endpoint won't accept a regular API token.

Both flows are env-aware (production vs sandbox) and pick credentials from `config.salesforce` / `config.sandbox` / `config.mcpApp` / `config.mcpSandbox` accordingly.

### Auth gating
`server/src/middleware/auth.ts` exports `requireAuth`, which 401s if `req.session.sf?.accessToken` is missing. `server/src/index.ts` mounts every `/api/*` router behind it; only `/auth/*` and `/api/health` are public.

### Session typing
`server/src/types/index.ts` augments `express-session`'s `SessionData` with `sf` and `mcpToken`. All shared response types (FlowDetail, ApexDetail, FieldUsageTree, AIExplanation) also live there and are duplicated in `client/src/lib/api.ts`.

### Salesforce calls
`server/src/services/salesforce.ts` exposes `getConnection(session.sf)` which returns a `jsforce.Connection` configured with the user's tokens — every route service grabs a connection this way. The MCP-hosted variant is in `server/src/services/sfMcpClient.ts`, which opens a `StreamableHTTPClientTransport` to `https://api.salesforce.com/platform/mcp/v1/...` per call.

### AI features (Anthropic SDK)
`server/src/services/ai.ts` runs flow/Apex explanations and Well-Architected assessments. `server/src/services/architect.ts` is the agentic loop — it defines a tool schema that maps Anthropic tool calls to jsforce operations (`sf_query`, `sf_tooling_query`, `sf_create_field`, `sf_create_validation_rule`, etc.) and is invoked from the cleanup/architect route. The current model ID hardcoded in these files is `claude-sonnet-4-20250514`; it lives in **three places** now — `server/src/services/ai.ts`, `server/src/services/architect.ts`, and `slack-bot/src/constants.ts`. Bump all three together when upgrading.

### Bulk match (`server/src/services/bulkMatcher.ts`)
CSV upload → in-memory job store keyed by `jobId` → background match/update jobs → client polls `/api/bulk/jobs/:id/status`. State is lost on server restart. Multer writes uploads to `os.tmpdir()`.

### Frontend conventions
- React Router routes are flat in `client/src/App.tsx`.
- All data fetching goes through the single `api` object in `client/src/lib/api.ts` (uses `fetch` with `credentials: "include"` to send the session cookie). Custom hooks in `client/src/hooks/` wrap individual endpoints.
- If `useSalesforceAuth` reports unauthenticated, `App.tsx` short-circuits to `<LoginButton/>` instead of rendering the layout.

### Standalone MCP server (`mcp-server/`)
Three auth strategies, tried in order, inside `getConnection()`:
1. `SF_ACCESS_TOKEN` + `SF_INSTANCE_URL` env vars (direct token).
2. `~/.sf_mcp_tokens.json` written by `mcp-server/src/auth.ts` (one-time browser OAuth on `localhost:9876`, supports MFA, auto-refreshes).
3. Username + password (+ optional security token) env vars (no MFA).

Run the one-time auth helper with:
```
cd mcp-server && SF_CLIENT_ID=... SF_CLIENT_SECRET=... SF_LOGIN_URL=... npx tsx src/auth.ts
```
Tools defined: SOQL/Tooling queries, describe, list objects, CRUD on custom fields/objects, validation rules, flow activate/deactivate, permission set assign/remove, generic record CRUD, and a raw `sf_deploy_metadata` escape hatch.

### Slack standup bot (`slack-bot/`)

Proactive agent that, at each rep's preferred local time, pulls today's Gong calls + their open Salesforce Opportunities + per-account usage and DMs a thread of recommendation cards. Buttons apply field updates back to Salesforce. Runs on Vercel (separate deploy from the local SF Visualizer).

Entrypoints under `slack-bot/api/`:
- `POST /api/slack/events` — Bolt receiver (slash commands, button actions, modal submissions).
- `GET /api/oauth/sf/start?slack_user_id=…` + `GET /api/oauth/sf/callback` — per-rep PKCE flow against the existing Salesforce Connected App. Add the Vercel `/api/oauth/sf/callback` URL to the Connected App's allowed callbacks.
- `POST /api/cron/tick` — fires every 5 minutes via Vercel Cron; matches reps whose preferred local time is in the last 5 minutes and triggers `/api/standup/run` per rep.
- `POST /api/standup/run` — runs the standup pipeline for one rep (gated by `STANDUP_INTERNAL_SECRET`). `maxDuration: 300`.
- `POST /api/nooks/webhook` — receives Nooks `call.completed` events. Auth: `x-nooks-secret` header against `NOOKS_WEBHOOK_SECRET`. v1 just logs the payload and DMs `NOOKS_TEST_DM_USER_ID` (a single Slack user id) with a digest card + raw JSON so you can see what Nooks sends. No persistence, no SF writes. See `src/services/nooksHandler.ts`.
- `POST /api/gong/webhook` — receives Gong post-call events. Auth (env-gated, checked in this order): (1) signed JWT in `Authorization: Bearer …` / `x-gong-signature` / `x-gong-jwt` header verified with `GONG_JWT_PUBLIC_KEY` (RS256) or `GONG_JWT_SECRET` (HS256), 5-min `iat` tolerance; (2) URL token `?token=<GONG_WEBHOOK_TOKEN>` (or `x-gong-token` header), constant-time compare; (3) if neither env is set, the endpoint accepts unauthenticated POSTs and warns — for initial wire-up only. Always returns 200 (even on auth failure) so Gong doesn't retry-storm. Logs the full header digest + parsed payload for the first events so the type can be tightened from real samples. Routing: extract `hostEmail` (falls back to `parties[].isHost === true`) → `getUserByEmail` → DM the rep only if `users.gong_realtime_enabled = true`. Audit action: `gong_realtime_surfaced`. No `pending_cards` row in v1, no SF writes. See `src/services/gongWebhookHandler.ts` and `src/services/gongWebhookAuth.ts`.

Persistent state lives in **Vercel Postgres** (or any `POSTGRES_URL`-compatible DB). Tables: `users`, `sf_tokens`, `sf_oauth_state`, `pending_cards`, `audit_log`. Apply with `npm run migrate -w slack-bot` against `POSTGRES_URL`.

Local dev: `npm run dev -w slack-bot` runs `scripts/devServer.ts` on port 3002, dispatching to the same handlers Vercel uses. Use ngrok to expose for Slack webhooks.

Key services:
- `src/services/runner.ts` — the standup pipeline. Pulls context, fans out per-opp recommendation calls (concurrency 3), posts thread parent + per-opp cards, records audit rows.
- `src/services/opportunityContext.ts` — single-query bulk fetch of opps + `OpportunityHistory` + Tasks/Events; joins with usage rows from `usageDb`.
- `src/services/recommender.ts` — one Claude call per opp, Zod-validated JSON (`RecommendationSchema` in `src/types.ts`). Strips out null / no-change fields.
- `src/services/salesforceClient.ts` — same shape as `server/src/services/salesforce.ts:getConnection`, but reads tokens from Postgres and persists rotated tokens via `conn.on('refresh', …)`.
- `src/services/usageDb.ts` — `UsageProvider` interface. Ships `RogoUsageProvider` (talks the Felix / Rogo Analytics Bot API contract) and `NoopUsageProvider` (used when `ROGO_API_KEY` is empty). `RogoUsageProvider` bootstraps once via `GET /api/start-here` (cached in module scope, so once per cold start), translates each Salesforce `Account.Id` to a Rogo customer key via `customer_directory.rows`, then fans out a single `POST /api/query/batch` (up to 10 datasets per request, chunked) against `ROGO_CUSTOMER_TABLE`. The join column names are env-tunable (`ROGO_DIRECTORY_SF_KEY`, `ROGO_DIRECTORY_CUSTOMER_KEY`, `ROGO_CUSTOMER_JOIN_COLUMN`) — start from the defaults and adjust after running `npm run probe -w slack-bot rogo-bootstrap` to see the actual directory shape.
- `src/services/rogoClient.ts` — thin wrapper over the Felix API surface: `bootstrap()`, `query()`, `queryBatch()`, `lookupRogoCustomer()`. Errors are surfaced as `RogoApiError` carrying the API's `error.code`; only `query_timed_out`, `snowflake_unavailable`, and `internal_error` are retryable per the memo. We do not use `/api/ask` in v1 — the recommender does its own reasoning.

Conventions specific to the bot:
- Per-rep Salesforce auth (no service account). Each rep runs `/standup connect` once.
- `STANDUP_DRY_RUN=true` makes `sfWriter` log audit rows but skip the SF update — use it on Vercel preview deployments. Also short-circuits the Gong realtime DM (audit row only, no Slack post).
- Action IDs encode card + field: `<verb>:<cardId>:<field>` (`accept`, `edit`, `skip`, `apply_all`). Don't change this shape without updating `slack/blocks.ts:parseActionId` and `slack/interactivity.ts`.
- **Per-rep real-time subscriptions** live on a separate surface from standup config: `/subscriptions` (and `/subscriptions_dev` in the dev workspace) opens `subscriptionsModalView` (`slack/subscriptionsModal.ts`). Two input blocks (Gong + Nooks), each with two checkboxes: a per-host "DM me after every X I host/make" and an admin firehose "(Admin) DM me every X across the org". Backed by `users.gong_realtime_enabled`, `users.gong_firehose_enabled`, `users.nooks_realtime_enabled`, `users.nooks_firehose_enabled`. The submit handler is `registerSubscriptionsSubmit` in `slack/interactivity.ts`; it writes via `updateSubscriptionPrefs` so it doesn't touch the standup columns. Adding a feed = one input block in the modal + two columns on `users` + one branch in the webhook handler that fans out to `getUserByEmail(host)` + `getFirehoseSubscribers(feed)`, deduped.
- **Webhook fan-out:** both `gongWebhookHandler` and `nooksHandler` route to a `Map<slackUserId, 'host' | 'firehose' | 'legacy_env'>` so the same user never gets two DMs for the same event. Each routed user gets an audit row (`gong_realtime_surfaced` / `nooks_realtime_surfaced` with `metadata.routing`). The Nooks env var `NOOKS_TEST_DM_USER_ID` is now a **legacy fallback** — only used if no DB subscribers match. Once the admin enrolls themselves via `/subscriptions` (Nooks firehose), unset the env var.

**Buy-signal AE notifications** — augment to the standup DM. After the per-opp loop, `runStandupForUser` calls `runBuySignalsForUser` (`slack-bot/src/services/buySignals.ts`), which loads the rep's owned Accounts, queries `Task` where `Subject LIKE '%[Apollo]%Connected - Positive%'` and `ActivityDate >= LAST_N_DAYS:7` against those accounts, filters out accounts that already have an open Opportunity, dedupes against buy-signal `pending_cards` posted to this rep in the past 7 days (`getRecentBuySignalAccountIds`), then per surviving account calls a per-account recommender (`slack-bot/src/services/buySignalRecommender.ts`, Zod-validated, same shape as the standup recommender) for a `headline` + `suggestedAction` ∈ {`create_opportunity`, `log_task`, `no_action`} + concrete pre-filled `suggestedOpp` / `suggestedTask`. Up to 5 cards (`buySignalCard`) post into the same standup thread; if standup had no opps, buy-signals owns the thread parent. Cards have three buttons: **Create opportunity** opens a modal pre-filled with the recommended name/stage/amount/closeDate → `sfWriter.createOpportunity` runs and posts an "Opp created → link" thread reply; **Log follow-up task** opens a modal pre-filled with the recommended subject/dueDate → `sfWriter.createTask` runs; **Skip** marks `pending_cards.status='skipped'`. `pending_cards.kind='buy_signal'` and `opportunity_id` is null; payload lives in `recommendation` JSONB. Constants in `slack-bot/src/constants.ts`: `BUY_SIGNAL_LOOKBACK_DAYS`, `BUY_SIGNAL_DEDUP_DAYS`, `BUY_SIGNAL_MAX_CARDS_PER_RUN`, `BUY_SIGNAL_SUBJECT_PATTERN`. Dry-run with `npm run probe -w slack-bot buy-signals <slack_user_id>` — runs the full pipeline, prints accounts/calls/recommendations, posts nothing.

**Post-Sales agent (`@merlin` Q&A + Brief)** — shared Anthropic tool-use loop in `slack-bot/src/agent/` (`runner.ts`, `tools.ts`, `prompts.ts`). Exposed to reps via DM only:
- `app.message` handler in `slack/mentions.ts` routes DM text. Prefix `brief <account>` → `services/brief.ts` (Block Kit `briefCard` with action buttons; disambiguates on multiple Account matches). Anything else → `services/qa.ts` (placeholder "Thinking…" + `chat.update` with the agent's final text).
- `app_mention` in channels gets a polite "DM me" ephemeral. No channel Q&A in v1.
- Read-only tools: `sf_find_account`, `sf_get_account_summary`, `sf_get_activities`, `sf_query` (SELECT only — DML rejected), `gong_get_calls`, `rogo_get_usage`, `now`. Writes still flow through button → `sfWriter` so audit semantics match the standup.
- `pending_cards.kind` discriminates `'standup'` vs `'brief'`; `opportunity_id` is nullable so brief cards can attach to an account. Existing handlers narrow on `card.kind === 'standup'`.
- Slack manifest needs `app_mentions:read`, `im:history`, `im:read` scopes plus event subscriptions `app_mention` + `message.im`. Reinstall the app after changing these.
- Probe the agent offline: `npm run probe -w slack-bot agent brief <slack_user_id> "Acme Corp"` or `agent qa <slack_user_id> "<question>"`.

After pushing slack-bot changes:
```
cd ~/sf-visualizer
git pull
cd slack-bot
npm install            # only if package.json changed
vercel deploy --prod   # if linked to Vercel
```
For local dev: `npm run dev -w slack-bot` (port 3002). Migration: `POSTGRES_URL=… npm run migrate -w slack-bot`.

## Conventions

- Server imports use explicit `.js` extensions on relative paths (required by ESM resolution even though source is `.ts`).
- Route errors are caught and surfaced as `res.status(500).json({ message: err.message })`; the client `request()` helper reads `message` to throw.
- All credentials flow through `server/src/config.ts` (web app) or `slack-bot/src/config.ts` (bot) from the root `.env` — don't inline secrets.
