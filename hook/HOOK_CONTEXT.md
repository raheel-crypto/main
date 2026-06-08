# Hook — Context Handoff

You are taking over development of **Hook**, Rogo's ARR reconciliation agent. This document captures every decision, design choice, and gotcha so you can pick up exactly where the previous session left off.

---

## 1. What Hook is

Hook is an autonomous + conversational agent that keeps Rogo's Annual Recurring Revenue (ARR) data clean in Salesforce. It:

- **Detects ARR gaps** in real time when opportunities change (Apex trigger → HMAC-signed callout → §2 recompute → diff vs stored).
- **Runs a weekly reconciliation** across all customer accounts (Vercel Cron).
- **Maintains an audit ledger** (`ARR_Event__c` in Salesforce) that mirrors §2's deterministic event chain.
- **Cross-validates against signed contracts** via the `Order_Form_Extraction__c` (OFE) object.
- **Posts findings to #revops** in Slack with a Claude-narrated explanation.
- **Lets revops chat with Hook** via `/hook` slash commands, `@Hook` mentions, and auto-listen in any thread Hook participated in.
- **Proposes corrective writes** as Slack buttons with explicit confirmation, audit trail (who clicked, when, before/after), and an optional fully-automated tier for unambiguous deal types.

The name: pirates say ARR.

---

## 2. Tech stack

| Layer | Tool |
|---|---|
| Runtime | Vercel (serverless, Node 18+) |
| Framework | Next.js 15 (App Router) |
| Language | TypeScript |
| Database | Neon Postgres (serverless driver `@neondatabase/serverless`) |
| LLM | Anthropic Claude Opus 4.8 with adaptive thinking |
| Salesforce client | `jsforce` v3 with JWT bearer auth |
| Slack client | `@slack/web-api` |
| Tests | Vitest |
| Deploy | GitHub push → Vercel auto-deploy |

**Model:** `claude-opus-4-8` with `thinking: {type: "adaptive"}` and `output_config: {effort: "high"}`. Prompt caching enabled on the system prompt via `cache_control: {type: "ephemeral"}`. Tool definitions are raw JSON Schema (not Zod) with a manual agentic loop — `betaZodTool` was tried and had Zod version compatibility issues, so we dropped it.

---

## 3. The canonical ARR rule (§2 of the build spec)

ARR is **NOT** a naive sum of closed-won opp ARR. The correct rule is an ordered, event-by-event running build per account:

```
INPUT:  all Opportunities where AccountId = A and IsWon = true
OUTPUT: Account.ARR__c expected value + the event ledger

1. SORT opps by (CloseDate ASC, TypePriority ASC) where
       TypePriority = { Renewal:0, Contract Restructure:1, New Business:2,
                        Upsell:3, Downsell:3, Debooking:3, Pilot:4 }
   -> guarantees a renewal rebaselines BEFORE same-day expansions are applied.

2. running = 0
   FOR each opp in sorted order:
       arr = opp.Annual_Recurring_Revenue__c   (treat null as 0)
       SWITCH opp.Type:
         New Business | Upsell | Pilot      -> delta = arr
         Downsell | Debooking               -> delta = arr  (value is already negative)
         Renewal                            -> delta = arr - running   (REBASELINE)
         Contract Restructure               -> if CloseDate == lastRenewalDate: delta = 0
                                               else: delta = arr
       running += delta

3. IF Account_Status__c == 'Former Customer' AND running > 0:
       emit synthetic Churn event with delta = -running
       running = 0

4. STATUS GATE:
       IF Account_Status__c IN ('Prospect','Former Customer'): Account.ARR__c = 0
       ELSE:                                                    Account.ARR__c = running
```

**Why each clause exists:**
- **Renewal rebaselines** — a renewal is the new annual contract value, which already incorporates prior expansion. Summing it on top double-counts. Delta-to-running makes the total *become* the renewal value regardless of history.
- **Same-day type priority** — when Upsell closes same day as Renewal, renewal first (resets base), then upsell (adds).
- **Restructure same-day as renewal = absorbed** — paper unwind the renewal already supersedes.
- **Pilots count when they have ARR** — most pilots are $0; paid pilots are real land. Don't blanket-exclude by Type.
- **Churn event** — explicit ledger row, delta = −running, keeps ledger self-consistent.
- **Status gate** — only Customers carry ARR. Prospects/Former Customers are $0 by definition.

This algorithm is implemented in `src/lib/arr/recompute.ts` and locked in by 15 tests in `src/lib/arr/recompute.test.ts` and `src/lib/arr/snapshot.test.ts`. **Never modify the algorithm without re-running the regression test against the production snapshot — the test asserts 326/334 accounts reconcile exactly.**

---

## 4. Edge cases (§4 reference)

These are the canonical scenarios encoded in unit tests. If you change §2, all of these must still pass:

| # | Scenario | Example | Handling |
|---|---|---|---|
| 1 | Renewal must not stack | Cordis ($12k land → $6k renewals) | Renewal delta = arr − running |
| 2 | Same-day renewal + upsell | William Blair ($270k + $230k = $500k) | TypePriority sort |
| 3 | Same-day renewal + restructure | Moelis ($500k + −$570k → $500k) | Restructure on renewal date → delta 0 |
| 4 | Mid-cycle restructure | (none in prod yet) | delta = arr |
| 5 | Paid "Pilot" | Stifel ($100k pilot) | Pilot delta = its ARR |
| 6 | Churn zeroes ARR | MIG, IGP | Synthetic Churn event, delta = −running |
| 7 | Prospect with closed-won | Hamilton Lane | Status gate forces ARR = 0 |
| 8 | Downsell / Debooking | (none) | delta = arr (already negative) |

---

## 5. Data-quality guard categories (§6.6)

When the recompute disagrees with stored ARR, Hook classifies the gap into exactly one of:

- **(a) Duplicate opps** — two won opps, same account, overlapping scope, both `New Business` (Arma pattern — now resolved).
- **(b) Restatement** — a later deal whose ARR equals the new total rather than the increment (Latimer/Sazun pattern).
- **(c) Type hygiene / mistyped opp** — opp name contains "Upsell"/"Renewal" but `Type = New Business` (Indeed/EEP pattern).
- **(d) Stale-on-churn** — Former Customer with non-zero stored ARR (IGP pattern — true error).
- **(e) Manual override** — `ARR_Locked__c = TRUE` → log only, do not propose a fix.
- **(f) Missing rollup** — clean recompute delta with no other category — likely a Salesforce automation gap.

OFE adds three more deterministic-detection categories on top of §6.6:
- **Contract-ARR mismatch** — `Opp.Annual_Recurring_Revenue__c != OFE.Annual_Recurring_Revenue__c`
- **Type mismatch vs contract** — `Opp.Type != OFE.Type__c`
- **Mistyped amendment** — `OFE.Is_Amendment = true` but `Opp.Type = New Business`

---

## 6. Known exceptions (§8, current as of last re-baseline)

These are accounts where Hook's recompute deliberately disagrees with stored Account.ARR__c — all are real data-quality issues, not algorithm bugs. The list lives in **two places** that must stay in sync:

- `src/lib/arr/snapshot.test.ts` → `KNOWN_EXCEPTIONS` constant (the regression test)
- `src/lib/claude/system-prompt.ts` → `## Known exceptions (§8)` section (what Hook tells users)

**Workflow when an exception is resolved:** re-pull the snapshot fixtures, update `KNOWN_EXCEPTIONS`, update the system prompt's §8 list, update the count in `it("reconciles N of 334 accounts exactly")`, run `npm test`, commit. There's an inline reminder comment in the system prompt about this.

Current 8 exceptions (resolved as of latest re-baseline):

| Account | Gap | Reason |
|---|---|---|
| Industrial Growth Partners | $23k | Stale-on-churn — true error |
| Indeed | -$18k | Type hygiene — Upsells typed as NB |
| Entrepreneur Equity Partners | -$12k | Type hygiene |
| Sazun GmbH | -$4.75k | Restatement |
| Latimer Partners | -$3k | Trial restated, supersession pending |
| Nolan & Associates | $1k | Immaterial — confirmed correct |
| Multiples Alternate Asset Management | -$130k | Investigating with revops |
| Alyeska Investment Group | $6k | Investigating with revops |

---

## 7. Architecture

```
Salesforce                            Vercel (arr-agent.vercel.app)                Slack
─────────────                         ────────────────────────────────────         ─────
Opp after-insert/update trigger       ┌─ POST /api/sf/opp-changed ───────┐
  ARR_Hook_Trigger.trigger            │   1. Verify HMAC                  │
  └─ @future callout (signed) ───────▶│   2. Query Account + Opps + OFEs  │
     ARR_Hook_Callout.cls             │   3. §2 recompute                 │
     reads Hook_Config__mdt           │   4. Write to Postgres (runs)     │
                                      │   5. Sync ARR_Event__c ledger     │
SOQL/SObject (jsforce + JWT) ◀────────│   6. Cross-validate against OFEs  │
                                      │   7. If gap: askHook → narrative  │
                                      │   8. Propose actions, persist     │
                                      │   9. Post to Slack with buttons   │
                                      │      (or auto-apply if eligible)  │────────▶ #revops post
                                      │                                   │
Vercel Cron (Mon 6am ET) ────────────▶│  GET /api/cron/weekly             │
  + Hook run_full_sweep tool          │   Returns 200 immediately         │
                                      │   after() fans out to 305+ accts  │
                                      │   Each → /api/cron/recompute-acct │────────▶ Weekly digest
                                      │                                   │
Slack Events API ────────────────────▶│  POST /api/slack/events           │
  app_mention + message.channels      │   handleMention + auto-thread     │────────▶ Threaded replies
                                      │                                   │
Slack slash commands ────────────────▶│  POST /api/slack/commands         │
  /hook recheck|explain|audit|help    │   parseCommand + ack + after()    │────────▶ Replies
                                      │                                   │
Slack interactivity ─────────────────▶│  POST /api/slack/interactions     │
  Button clicks                       │   loadAction + executeAction      │────────▶ Updates message
                                      │   chat.update with ✓ stamp        │           with audit line
                                      └───────────────────────────────────┘
```

---

## 8. File map (Hook's source tree)

Paths are relative to Hook's project root. In the monorepo, prefix with the package directory.

```
src/
  app/api/
    sf/opp-changed/route.ts         # SF Apex callout webhook (HMAC verified)
    cron/weekly/route.ts            # Vercel Cron + run_full_sweep target. Returns immediately, work in after()
    cron/recompute-account/route.ts # Per-account fan-out worker
    slack/events/route.ts           # app_mention + message.channels (auto-listen in threads)
    slack/commands/route.ts         # /hook subcommands with pirate-themed acks
    slack/interactions/route.ts     # Button clicks — loads + executes pending_actions
  lib/
    arr/
      types.ts                      # AccountRecord, OpportunityRecord, OrderFormExtraction, ArrEvent
      recompute.ts                  # §2 algorithm: recomputeAccount, diffVsStored
      recompute.test.ts             # 11 synthetic edge case tests
      snapshot.test.ts              # 4 regression tests against prod fixture
      __fixtures__/
        accounts.json               # 334 customer accounts (re-baseline by re-pulling)
        opps.json                   # 494 won opps
      cross_validate.ts             # OFE vs Opp validation (3 categories)
    salesforce/
      client.ts                     # JWT bearer auth, token cached in Postgres
      soql.ts                       # getAccountWithOpps (returns account + opps + ofes), rawSoql
      ledger.ts                     # syncAccountEvents — delete-then-insert ARR_Event__c per account
      writes.ts                     # updateAccountArr, setOppLocked
    slack/
      client.ts                     # WebClient with bot token
      blocks.ts                     # issueBlocks, autoAppliedBlocks, appliedActionBlocks, weeklyDigestBlocks
    db/
      client.ts                     # Lazy Neon proxy (defers neon() until first query)
      schema.sql                    # All tables and indexes
    claude/
      system-prompt.ts              # Hook's "brain" — §2, §4, §6.6, §8, OFE section, sweep instructions
      tools.ts                      # 5 tool definitions + 5 executor functions
      agent.ts                      # askHook — manual agentic loop, Opus 4.8, MAX_TURNS=10
    actions/
      propose.ts                    # proposeActions, buildRecommendations, isAutoApplyEligible
      execute.ts                    # loadAction, executeAction — runs the SF write, stamps audit fields
    hmac.ts                         # signPayload, verifyHmac, verifySlackSignature

apex/
  ARR_Hook_Trigger.trigger          # Fires on opp won/changed
  ARR_Hook_Callout.cls              # @future HMAC-signed POST to Hook
  ARR_Hook_Callout_Test.cls         # Test class for 75% coverage

vercel.json                         # Cron schedule + maxDuration per route (all 60s)
.env.example                        # All required env vars
```

---

## 9. External services configured

### Salesforce
- **Connected App** with JWT Bearer flow, cert pair generated locally, public key uploaded
- **Apex** deployed to production: trigger + callout class + test class
- **Custom Metadata** `Hook_Config__mdt` with `Endpoint_URL__c` and `HMAC_Secret__c`, one record named `Default`
- **Remote Site Setting** `Hook_Vercel` pointing at `https://arr-agent.vercel.app`
- **Custom fields:**
  - `Opportunity.ARR_Locked__c` (Checkbox, default unchecked) — when TRUE, Hook does not propose writes on this opp
  - `Account.ARR__c` (Currency) — the stored ARR being maintained
  - `Account.Account_Status__c` (Picklist: Prospect, Customer, Former Customer)
  - `Account.Churn_Date__c` (Date) — sparsely populated, needed for churn events
- **`ARR_Event__c` custom object** — the audit ledger, backfilled. Hook maintains it on every recompute via `syncAccountEvents()`. Picklist for `Event_Type__c` has stray tabs on the "Churn" value (admin entry quirk) — `ledger.ts` handles this with `SF_CHURN_PICKLIST_VALUE = "Churn\t\t\t"`.
- **`Order_Form_Extraction__c` custom object** — LLM-extracted contract data. One row per signed PDF, linked via `Opportunity__c`. Hook cross-validates Opp.ARR vs OFE.ARR.

### Slack
- App named **Hook** with bot token, signing secret, channel ID for `#revops`
- Scopes: `chat:write`, `app_mentions:read`, `commands`, `channels:history`
- Event subscriptions: `app_mention`, `message.channels`
- Slash command: `/hook` → `/api/slack/commands`
- Events URL: `/api/slack/events`
- Interactivity URL: `/api/slack/interactions`

### Anthropic
- Single API key, no Bedrock/Vertex
- Model: `claude-opus-4-8`
- Cached system prompt; one cache-write per system-prompt change

### Neon Postgres
- Vercel integration; `DATABASE_URL` auto-set
- Schema in `src/lib/db/schema.sql`; apply via Neon SQL Editor

---

## 10. Environment variables (Vercel)

```
ANTHROPIC_API_KEY              # Claude API key
DATABASE_URL                   # Neon connection string

SF_LOGIN_URL                   # https://login.salesforce.com (or sandbox URL)
SF_CLIENT_ID                   # Connected App consumer key
SF_USERNAME                    # SF user the JWT impersonates
SF_PRIVATE_KEY                 # Multi-line PEM, paired with cert uploaded to Connected App
SF_CALLOUT_HMAC_SECRET         # HMAC secret — must match Hook_Config__mdt.HMAC_Secret__c

SLACK_BOT_TOKEN                # xoxb-...
SLACK_SIGNING_SECRET           # For request verification
SLACK_REVOPS_CHANNEL_ID        # Where Hook posts gaps and digests

CRON_SECRET                    # For Vercel Cron auth + Hook self-call to /api/cron/weekly
HOOK_BASE_URL                  # Optional. Defaults to https://${VERCEL_URL}

HOOK_DRY_RUN=true              # Reserved; not yet used to gate writes
HOOK_GAP_THRESHOLD_USD=1       # Gap threshold for §2 mismatch detection
HOOK_AUTO_CORRECT=false        # When true, eligible accounts auto-apply without a button click
```

---

## 11. Postgres schema (key tables)

```sql
-- One row per Salesforce JWT access token (singleton, cached for 2h)
sf_token_cache (id, access_token, instance_url, expires_at)

-- One row per Hook invocation
runs (id, trigger_kind, account_id, started_at, finished_at, accounts_checked, gaps_found, digest_message_ts)

-- One row per §2 mismatch detected
gaps (id, run_id, account_id, account_name, stored_arr, expected_arr, gap_usd, category, rule_applied, created_at, slack_message_ts)

-- Thread context for follow-up Q&A
slack_threads (thread_ts PK, channel_id, account_id, run_id, context JSONB, created_at)

-- Write proposals → button clicks → audit log
pending_actions (
  id, kind, account_id, opportunity_id, target_object, target_field,
  current_value, proposed_value, button_text, button_style, confirm_text, reason,
  gap_id, slack_channel_id, slack_message_ts,
  created_at, applied_at, applied_by_slack_user_id, applied_by_slack_user_name,
  result, error_message
)
```

---

## 12. Hook's tool surface

Hook (the Claude agent) has 5 tools. All defined in `src/lib/claude/tools.ts` as raw JSON Schema + executor map. Names + when Hook should use them:

| Tool | Purpose | When Hook uses it |
|---|---|---|
| `soql_query` | Read-only SOQL against any SF object | Raw queries when no dedicated tool fits |
| `recompute_account` | Run §2 algorithm on one account | "What should this account's ARR be?" |
| `diff_vs_stored` | Recompute + compare to stored | Investigating a known gap |
| `last_audit` | Pull recent Hook gap history for an account | "Has this been reported before?" |
| `validate_contracts` | Cross-validate opps vs OFE for an account | Any data-quality investigation |
| `run_full_sweep` | Kick off `/api/cron/weekly` async | "Check all accounts" / "full ARR check" |

The system prompt instructs Hook to **never compute ARR itself** — always go through `recompute_account` or `diff_vs_stored`.

---

## 13. Conversational features

| Surface | Behavior |
|---|---|
| `/hook recheck <account>` | Fresh recompute, posts narrated result. Pirate ack: "Diving for treasure on *X*…" |
| `/hook explain <opp-id>` | Walks through one opp's incremental ARR. Ack: "Pulling the ship's log on *X*…" |
| `/hook audit` | Summary of this week's reconciliation (reads from `gaps` table). Ack: "Hoisting this week's ledger…" |
| `/hook help` | Help text returned inline (no Claude call) |
| `@Hook <question>` at top level | Hook responds in a new thread under the @mention. Persists context. |
| `@Hook` in any thread | Loads prior turn from `slack_threads`, responds with history |
| Plain message in a thread Hook started | Auto-listen — Hook responds without explicit @mention (filtered to threads Hook has participated in) |
| Hook posts a gap to #revops | Buttons for "Sync ARR" and "Lock Opp" appear inline; click → execute → message updates with ✓ stamp |

Slash command acks return immediately as an ephemeral message; the full answer is posted via `chat.postMessage` after the agent loop completes (using `after()` from Next 15 to bridge the response → background work gap).

@mention path posts a "Squinting at the charts…" placeholder immediately, then `chat.update`s it with the real reply when ready.

---

## 14. Write workflow (human-in-the-loop)

When Hook detects a §2 gap, it:

1. Generates a list of `ProposedAction`s via `proposeActions(gap, account, opps)`
2. Inserts each as a `pending_actions` row
3. Renders buttons in the Slack post, each carrying the row ID as the button value
4. On click → `/api/slack/interactions` → verify Slack signature → load row → execute SF write → stamp the row with `applied_by_slack_user_id`, `applied_by_slack_user_name`, `applied_at`, `result` → `chat.update` the message with a green check or red ⚠ summary

Two action kinds today:
- `sync_account_arr` — set `Account.ARR__c` to §2 expected
- `lock_opp` — set `Opportunity.ARR_Locked__c = true` (silences future Hook proposals on this opp)

Idempotency: if `applied_at` is set on the row, clicking again returns "already applied by X" instead of re-executing.

### Tiered auto-apply (gated by `HOOK_AUTO_CORRECT=true`)

`isAutoApplyEligible(gap, account, opps, ofeGaps)` returns true when:
- No `ARR_Locked__c` on any opp
- No OFE disagreements
- Either:
  - Customer with all won opps in `{New Business, Pilot, Renewal}`, OR
  - Former Customer with stale ARR > 0 and expected = 0 (stale-on-churn)

When eligible AND env is on → Hook auto-applies without a button. Slack post uses `autoAppliedBlocks` (different header, green check, audit action # inline).

When eligible but env is OFF → button flow with a "Tier" context line explaining why the policy didn't fire automatically.

When not eligible → standard button flow.

---

## 15. OFE integration (current state)

OFE (`Order_Form_Extraction__c`) is Rogo's LLM-extracted contract data. Hook fetches OFE rows for every won opp via `getAccountWithOpps`, then runs `crossValidate(opps, ofes)` which produces `OfeGap[]` with categories:

- `Contract-ARR mismatch`
- `Type mismatch vs contract`
- `Mistyped amendment`

OFE gaps are surfaced in Claude's prompt context when §2 has a gap, so the narrative can cite contract evidence. They do NOT yet trigger their own Slack posts (v1 only posts on §2 gaps).

**Pending OFE work the user owns:**
- The user is updating OFE extraction to produce both:
  - `Annual_Recurring_Revenue__c` = new contract total ARR (current behavior)
  - `Incremental_ARR__c` = delta this contract adds (NEW field)
- Once both are populated, Hook should:
  - Compare `Opp.ARR` ↔ `OFE.Incremental_ARR__c` (delta check)
  - Compare §2 running-after-this-event ↔ `OFE.Annual_Recurring_Revenue__c` (chain check)
- These two checks fail in different ways and point at different fixes.

**Why this matters:** `Opp.Annual_Recurring_Revenue__c` represents incremental ARR (delta), but OFE currently extracts total ARR. They only align for Land/New Business opps. Comparing them directly produces false positives on Upsells, Renewals, Restructures.

---

## 16. Deployment workflow

**Branch:** Hook code currently lives in the user's new monorepo. The user previously developed on `claude/blissful-curie-xDaNY` in the sf-visualizer repo (used as a staging branch because the prior session's GitHub access was scoped to `raheel-crypto/main`). All changes are committed to this branch; sync to the production repo (`Rogo-Technologies/arr-agent`) happens manually via `cp`. **In the new monorepo, you can push directly without the cp dance** — confirm with the user whether GitHub access scope is now the monorepo.

**Test before push:**
```bash
cd <hook-package-dir>
npm test
# Should show: Test Files 2 passed (2), Tests 15 passed (15)
```

**Production deploy:** automatic on push to `main` of `Rogo-Technologies/arr-agent`.

**Re-baselining the snapshot fixture:**
1. Use the Salesforce MCP `soqlQuery` tool to pull current state:
   - `SELECT Id, AccountId, Annual_Recurring_Revenue__c, Type, CloseDate, IsWon, Name FROM Opportunity WHERE IsWon = true ORDER BY AccountId, CloseDate ASC`
   - `SELECT Id, Name, ARR__c, Account_Status__c, Churn_Date__c FROM Account WHERE Id IN (SELECT AccountId FROM Opportunity WHERE IsWon = true) ORDER BY Id`
2. Save as `src/lib/arr/__fixtures__/opps.json` and `accounts.json` (strip `attributes`)
3. Run a smoke script that ports §2 to plain JS and runs against the fixture; tally matches and mismatches
4. Update `KNOWN_EXCEPTIONS` in `snapshot.test.ts`
5. Update the system prompt's §8 list
6. Update the match count in `it("reconciles N of M…")`
7. Run `npm test` → green
8. Commit

---

## 17. Vercel function timeouts

All routes set to **60s max duration** in `vercel.json`. Anthropic Opus 4.8 with adaptive thinking + multiple tool calls can run 20-40s — 60s is the right ceiling.

If you ever see another timeout:
1. Check which route — slack/events vs sf/opp-changed vs cron
2. If Slack-side, consider switching narrator to `claude-sonnet-4-6` (one-line change in `agent.ts`) — Sonnet is 2-4x faster
3. If cron-side, fan-out concurrency may be hitting Vercel limits — chunk the per-account calls

**Vercel `after()` is heavily used** — Slack routes return ack within 3s, do work after response within the function's max duration. This is the official Next 15 way to defer work. `void`-fire-and-forget does NOT work on serverless (function instance dies when response is sent).

---

## 18. Open work / next priorities (when the user is ready)

1. **Wire OFE `Incremental_ARR__c`** once the user populates the field. Add it to `OrderFormExtraction` type, SOQL projection, and `crossValidate`. Surface per-opp recommendations in `buildRecommendations`.
2. **Flip `HOOK_AUTO_CORRECT=true`** — auto-apply the safe-tier writes (NB/Pilot/Renewal accounts and stale-on-churn). IGP would be the first auto-fix.
3. **Triage remaining exceptions** with revops: Multiples ($130k) is biggest unknown, Alyeska ($6k) is new since audit, IGP is the only true error.
4. **`/hook audit` could route through `run_full_sweep`** instead of reading from `gaps` table. Currently it summarizes history; a fresh sweep would be more useful for "what's the current state?"
5. **Duplicate detection via shared `Content_Document_Id__c`** — if two won opps have OFEs pointing to the same signed PDF, that's a deterministic dupe signal (replaces manual `ARR_Locked__c` workflow for the common case).
6. **Phase 4: contracts** — add a `Contract__c` validation layer once contract data lands in SF.

---

## 19. Important gotchas

- **System prompt is cached.** Changing `HOOK_SYSTEM_PROMPT` invalidates the cache (one-time write cost). Keep it byte-stable across requests. NEVER interpolate dates, user IDs, or request IDs.
- **Salesforce picklist for `ARR_Event__c.Event_Type__c.Churn` has trailing tabs** — `"Churn\t\t\t"` — admin entry quirk. The `ledger.ts` `SF_CHURN_PICKLIST_VALUE` constant handles this. Could be fixed in SF.
- **Neon `sql` template tag** has generic `<ArrayMode extends boolean>` — it's a flag, NOT the row type. Use `(await sql\`...\`) as RowType[]`. Never `sql<RowType>\`...\``.
- **jsforce v3** exports `Connection` as a named import. `import jsforce from "jsforce"` doesn't work for types.
- **`betaZodTool` was tried and removed** due to Zod version compatibility ("Cannot read properties of undefined (reading 'def')"). Tools are raw JSON Schema with a manual executor map.
- **Tests use real production fixture** (`accounts.json`, `opps.json` — 334 accounts, 494 won opps). Re-baseline regularly when prod data changes.
- **`KNOWN_EXCEPTIONS` exists in two places** — `snapshot.test.ts` AND `system-prompt.ts`. Always update both.
- **`isAutoApplyEligible` is intentionally conservative.** Don't expand to Upsells without an OFE-based incremental ARR validation.
- **`syncAccountEvents` uses delete-then-insert per account.** Every recompute changes `ARR_Event__c.CreatedDate`. Use `Event_Date__c` for the business date, not `CreatedDate`.
- **`message.channels` event sees every channel message** Hook has access to. Filtering is done in code: skip if `bot_id` set, has `subtype`, no `thread_ts`, contains `<@`, or no `slack_threads` row.
- **Slack interactions have a 3-second ack deadline.** Both interactions and commands return immediately and do work in `after()`.
- **The user is new to terminal/CLI workflows.** Provide full copy-paste command sequences when guiding through deployments. The user is on macOS (zsh/bash).

---

## 20. Useful queries for debugging

```sql
-- Recent gaps detected
SELECT account_name, stored_arr, expected_arr, gap_usd, created_at
FROM gaps
ORDER BY created_at DESC LIMIT 20;

-- All write actions Hook has executed
SELECT kind, account_id, target_field, current_value, proposed_value,
       applied_by_slack_user_name, applied_at, result, error_message
FROM pending_actions
WHERE applied_at IS NOT NULL
ORDER BY applied_at DESC;

-- Pending (unclicked) actions
SELECT id, kind, account_id, button_text, created_at
FROM pending_actions
WHERE applied_at IS NULL
ORDER BY created_at DESC;

-- Hook run history
SELECT trigger_kind, started_at, finished_at, accounts_checked, gaps_found
FROM runs
ORDER BY started_at DESC LIMIT 20;
```

```sql
-- Salesforce: current ARR_Event__c ledger for one account
SELECT Event_Date__c, Event_Type__c, Delta_ARR__c, Running_ARR__c, Note__c, Sequence__c
FROM ARR_Event__c
WHERE Account__c = '001V400000...'
ORDER BY Sequence__c
```

---

## 21. How to pick up where the last session left off

Read this doc end to end. Then:

1. Run `npm test` to confirm 15/15 pass — establishes the §2 algorithm is intact.
2. Glance at the most recent commits to see what's actively being worked on.
3. Check Slack for any recent Hook posts to see what's flowing in production.
4. Ask the user what they want next. Common requests:
   - "Add X button to Slack messages" — extend `propose.ts` and `execute.ts`
   - "Add a new tool" — extend `tools.ts` and the system prompt
   - "Validate against Y" — extend `crossValidate` or add a new validator
   - "Why did Hook flag X?" — use the SF MCP to query the data, then explain
   - "Re-baseline" — follow the re-baselining workflow above

Hook is a working production system. The §2 algorithm is canonical; the rest is iteration. When unsure, ask before changing anything in `recompute.ts`. Everything else is fair game.

🪝
