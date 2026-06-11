# Rogo Quote Bot — Handoff Doc

Snapshot of where the Slack-based quote/approval bot stands as of `2026-06-11`.
Use this as context for a new Claude session in the new monorepo.

## What this thing is

A Slack + Salesforce automation that:

1. Lets reps request a quote via `/quote` (Slack modal) OR via a Lightning
   Web Component (LWC) on the Opportunity record page.
2. Calculates pricing, picks an approval tier (auto / Deal Desk / Pod Leader
   / James) based on discount %, and posts an approval card to `#deal-desk`
   with Approve/Reject buttons.
3. On approval, generates a prefilled docx order form, DMs it to the rep,
   and mirrors it into the approval thread.
4. Has a parallel "signed order form received" path that prompts RevOps in
   the same thread to mark the Opp `Closed Won`.

Stack: TypeScript on Vercel (Fluid Compute), Upstash KV for state, Slack
Bot API, Salesforce REST API (`sfdc-auth.ts` handles OAuth), `docxtemplater`
for order forms, four `.docx` templates baked into the deploy bundle.

## Where the code lives (current repo)

```
.agents/skills/slack-agent/
├── api/
│   ├── jobs/process-quote.ts          # Background processor (fired by intake)
│   ├── sfdc/
│   │   ├── intake.ts                  # LWC → backend entry point
│   │   └── signed.ts                  # SFDC-triggered "signed form received"
│   └── slack/
│       ├── interactivity.ts           # Modal submits + button clicks
│       ├── quote.ts                   # /quote slash command (opens modal)
│       ├── quote-manual.ts            # /quote-manual (RevOps bypass)
│       ├── quote-override.ts          # /quote-override (admin force decision)
│       ├── quote-regenerate.ts        # /quote-regenerate (re-run doc gen)
│       └── quote-status.ts            # /quote-status (lookup by request ID)
├── lib/
│   ├── approval.ts                    # routeApproval + getAuthorization
│   ├── agent.ts                       # Claude prose-only summary (no numbers)
│   ├── blocks.ts                      # Slack Block Kit builders
│   ├── orderForm.ts                   # docx fill + deliverOrderForm helper
│   ├── pricing.ts                     # calculatePricing (all-in model)
│   ├── revops.ts                      # Channel posts + Quote_Approval__c writes
│   ├── sfdc-auth.ts                   # OAuth client-credentials flow
│   ├── sfdc-client.ts                 # SOQL helpers + DealContext shaping
│   ├── slack.ts                       # Slack Web API thin wrappers
│   ├── state.ts                       # Upstash KV stash/retrieve/drop
│   └── types.ts                       # Single source of truth for shapes
└── templates/
    ├── order-form-standard-new.docx
    ├── order-form-standard-existing.docx
    ├── order-form-enterprise-new.docx
    └── order-form-enterprise-existing.docx
```

Two LWCs in the Salesforce org (NOT in this repo — they live in SFDC
metadata):

- `quoteBotForm` — the form fields component
- `quoteBotModal` — the wrapper modal with two-column layout, pricing
  breakdown sidebar, and "Pod Leader Approval Required" routing banner

Both LWCs have their own clientside pricing math (`get calc()`) that
must mirror `lib/pricing.ts`. **Any pricing-model change requires
updating all three: backend + both LWCs.**

## Pricing model (settled — important)

`price_per_user` is the **ALL-IN annual rate per seat**. It includes the
hosting share and the credit-commit share. The customer pays exactly
`price_per_user × users` per year.

```
total / ARR     = price_per_user × users         ← what the customer pays
credits_commit  = total_credits × $0.02          ← internal allocation
hosting         = hosting_fee                    ← internal allocation
platform_fee    = total − credits_commit − hosting   (residual)
```

**Hosting and credits commit are NOT additive lines on top of the
per-user revenue — they're carved out of it for the order form
breakdown.** This was the cause of a recent $100K double-count bug
(commit `22ed2c3`).

Discount is the **simple comparison** of entered price vs list price.
Do NOT re-derive a "platform-only effective rate" — it inflates the
discount on deals that bundle hosting and disagrees with what reps and
managers see (commit `ed388db`).

```
discount_per_user = list_price − price_per_user
discount_pct      = discount_per_user / list_price
```

`list_price` is `null` for Enterprise (no discount math).

### Routing tiers (in `lib/approval.ts`)

| Discount band | Tier | Approvers |
|---|---|---|
| `< 20%` | `auto` | (none, auto-approved) |
| `20–30%` | `deal_desk` | Anyone in `DEAL_DESK_APPROVER_IDS` |
| `30–50%` | `pod_leader` | Opp Owner's Manager (resolved from SFDC) |
| `≥ 50%` | `james` | James OR anyone in `DEAL_DESK_APPROVER_IDS` |

`Enterprise` package overrides: always routes to Pod Leader regardless
of discount.

### Approval overrides (button-based)

Anyone in `DEAL_DESK_APPROVER_IDS` can click Approve/Reject on **any**
pending deal, not just deals routed to them. When they act on a deal
that wasn't routed to them, `decided_by_name` gets `(override)`
appended — same convention as `/quote-override`.

Logic: `getAuthorization(routing, slackUserId)` in `lib/approval.ts`
returns `{ authorized, isOverride }`.

## Slash commands

| Command | Who | Purpose |
|---|---|---|
| `/quote <opp>` | Any rep | Opens the standard quote modal |
| `/quote-status <request-id>` | Any rep | Look up the status of a past request |
| `/quote-manual <opp>` | `DEAL_DESK_APPROVER_IDS` | Like `/quote` but bypasses approvals — doc generated and DM'd directly to RevOps user, brief audit note in `#deal-desk` |
| `/quote-regenerate <request-id>` | `DEAL_DESK_APPROVER_IDS` | Re-run order form generation for an already-approved deal (state=approved required) |
| `/quote-override <request-id> approve\|reject` | `ADMIN_SLACK_USER_IDS` | Force a decision on a quote (even already-decided ones); auto-generates doc on approve |

All slash command endpoints are at `/api/slack/<command-name>` in the
Vercel deploy.

## Manager DM on Pod Leader routing

When a quote routes to `pod_leader` tier, the bot DMs the resolved
manager in addition to posting the channel card. DM contains a quote
summary + a deep link to the channel thread (built via
`https://slack.com/archives/<channel>/p<ts-without-dot>`).

Located in `api/jobs/process-quote.ts:notifyPodLeaderViaDM`. Best-effort
— failures are logged but don't block the channel post.

## Closed-Won flow

`api/sfdc/signed.ts` is the entry point — Salesforce calls it (or the
user does manually) when a signed order form is received. It looks up
the prior `Quote_Approval__c` audit row to find the original channel
thread:

- **Threaded path:** posts the "Mark Closed Won" prompt as a reply in
  the original approval thread.
- **Legacy path:** if no audit row exists (pre-launch deals), posts a
  fresh top-level message in `REVOPS_CHANNEL` with the same prompt.

When the **Mark Closed Won** button is clicked:
1. Auth check (RevOps only).
2. Updates the SFDC Opportunity `StageName = "Closed Won"`.
3. Replaces the prompt with a success block ("✅ X marked Closed Won by
   @alice at ...").
4. Posts a thread status note: "🏆 Marked Closed Won by @alice at
   `<iso>`" — mirrors the approval flow's thread status note so the
   activity is visible in the channel timeline (commit `57964fe`).

## SFDC integration

### Custom objects/fields the bot reads or writes

- `Account.Name`, `Account.Segment`
- `Opportunity` — Name, StageName, Amount, CloseDate, Type, Owner_id, etc.
- `Opportunity.Owner.Manager` — resolved through the User hierarchy for
  Pod Leader routing
- `User.Slack_User_Id__c` (custom field) — for mention resolution
- `Quote_Approval__c` (custom object) — audit log row per request:
  - `Request_Id__c` (External Id, unique)
  - `State__c`, `Decided_By_Name__c`, `Decided_At__c`
  - `Slack_Message_Url__c`
  - `Source__c` ("Slack" / "Salesforce")
  - Other pricing fields

### LWC ↔ backend contract

`POST /api/sfdc/intake` accepts:
```ts
{
  opportunity_id: string,
  form: {
    package: "Standard" | "Premium" | "Enterprise",
    users: number,
    price_per_user: number,        // ALL-IN per user
    total_credits: number,
    free_credits?: number,
    hosting_fee: number,
    pricing_discussed: boolean,
    contract_start_date: string,   // YYYY-MM-DD
    contract_end_date: string,
    notes?: string,
  },
  requester: {
    slack_user_id: string,         // Required — resolves the rep
    slack_user_name?: string,
  }
}
```

The LWC sends `price_per_user` as the all-in number. The backend treats
it as all-in (matching). Hosting is sent separately for the audit
breakdown but does NOT get added to total.

### LWC ↔ backend sync points (gotchas)

- **`PACKAGE_LIST_PRICE` must match between backend and both LWCs.**
  Backend has Standard, Premium, Enterprise. The user's LWCs added a
  `Plus` tier ($8,000) that the backend doesn't know about — quotes
  submitted with `package: "Plus"` will auto-approve regardless of
  discount because the backend can't compute a discount %. Fix: add
  `Plus` to `lib/pricing.ts:PACKAGE_LIST_PRICE` and to the `Package`
  union in `lib/types.ts`.
- **`packageOptions` labels in the LWC must match list prices.** Easy
  to forget when prices change.
- **Pricing math drift between backend and LWCs**: same `total`,
  `platform_fee`, `credits_commit`, `hosting`, `discount` formulas
  in all three. Any change requires touching all three. The current
  shared formula is the one above ("Pricing model").

## Slack environment vars

```
SLACK_BOT_TOKEN
SLACK_SIGNING_SECRET
REVOPS_CHANNEL                # Channel ID, not name
DEAL_DESK_APPROVER_IDS        # CSV of Slack user IDs (the RevOps group)
ADMIN_SLACK_USER_IDS          # CSV (smaller, for /quote-override)
JAMES_SLACK_USER_ID           # Single user ID for ≥50% escalation
```

## Salesforce env vars

```
SFDC_LOGIN_URL                # e.g. https://yourorg.my.salesforce.com
SFDC_CLIENT_ID                # Connected App
SFDC_CLIENT_SECRET
SFDC_USERNAME                 # For username-password OAuth
SFDC_PASSWORD                 # password + security token concatenated
```

## Vercel + Upstash

```
RUNNER_URL                    # The /api/jobs/process-quote endpoint (self-call)
RUNNER_SECRET                 # Shared secret for the self-call
UPSTASH_REDIS_REST_URL
UPSTASH_REDIS_REST_TOKEN
```

## Deferred / rolled-back work

We built a full **pre-approved legal terms library + master order form
template + per-category term routing** in early June, but rolled it
back before it landed in production because (a) the SFDC custom objects
and master `.docx` template weren't ready and (b) a Vercel deploy hit
an `ERR_MODULE_NOT_FOUND` for `fetchTermsByCodes` that we never fully
diagnosed.

The commits are in git history if you want to revisit:

- `76be34c` phase 2.5+: pre-approved legal terms library + master template support
- `4805845` orderForm: route selected_terms by Category__c into per-category buckets

What it added:

- `Legal_Term__c` SFDC custom object (admin-managed clause library)
- `Quote_Approval_Term__c` junction (per-clause audit rows)
- `SelectedTerm` snapshot on `QuoteForm` (terms frozen at submit)
- Term-tier bumping in `routeApproval` (e.g. Net 90 → Pod Leader even at
  0% discount)
- Master `order-form.docx` with `{{#isEnterprise}}…{{/isEnterprise}}`
  conditional sections replacing the 4 per-segment/per-type templates
- `{{#terms_payment}}`, `{{#terms_renewal}}`, etc. category-routed
  loops so legal can scatter clauses across the doc instead of all in
  one block
- LWC sends `selected_term_codes: string[]` in the intake payload;
  backend SOQL-resolves and snapshots them

When ready to bring this back:
1. Create the SFDC objects (Legal_Term__c, Quote_Approval_Term__c,
   plus `Term_Codes_Summary__c` Long Text on Quote_Approval__c).
2. Author the master `.docx` template (collapse the 4 existing files
   into 1 using `{{#isNewBusiness}}`/`{{#isEnterprise}}`/etc.
   conditional sections).
3. Update LWC to query `Legal_Term__c` and send `selected_term_codes`.
4. Cherry-pick / re-implement commits `76be34c` and `4805845`.
5. Investigate the Vercel `fetchTermsByCodes` import error before
   declaring victory (likely build cache, but verify).

## Recent commits (newest first)

```
ed388db  pricing: discount compares entered price to list directly
22ed2c3  pricing: treat price_per_user as all-in (fixes hosting double-count)
57964fe  closed-won: post who-did-it status note in the thread
854b1d9  Add /quote-manual and /quote-regenerate RevOps escape hatches
94f98b6  RevOps can override approvals via the channel buttons
21e43ec  quote-override: also generate the order form on force-approve
f8b36e3  Roll back legal terms + master template; keep pod-leader DM only
b05a339  DM pod-leader approvers with quote summary + thread deep-link
   (4805845 + 76be34c above this point are the rolled-back legal-terms work)
81f5a7d  closed-won prompt: add "View in Salesforce" link button
```

Current production branch: `claude/review-markdown-docs-oMOW3`. The
user deploys by manually copying to a separate enterprise GitHub that
Vercel auto-deploys from — **this Claude session never runs the Vercel
CLI**.

## User context (carry over to the new session)

- The user (Raheel, `raheel@rogo.ai`) is **new to terminal/CLI
  workflows**. Always provide full copy-paste command sequences when
  asking him to do anything in a terminal.
- He CANNOT run the Vercel CLI (`vercel deploy`, `vercel dev`, etc.) —
  his deploys are manual outside the Claude environment.
- After every push, the standard ritual is:
  ```
  cd ~/sf-visualizer
  git pull
  ```
  (and `npm install` inside `.agents/skills/slack-agent/` only if
  dependencies changed)
- He pushes from this Claude env to a working branch; then copies the
  diff to the enterprise GitHub manually to trigger Vercel.

## Quick-reference: known open items

- [ ] Add `Plus` package to backend `lib/pricing.ts` + `lib/types.ts`
      (currently only in LWCs; backend silently auto-approves).
- [ ] Sync `packageOptions` labels in the LWC with the actual list
      prices in `PACKAGE_LIST_PRICE` (was off — Standard label said
      $6,000 when the list was $7,500 until recently).
- [ ] (Eventually) ship the legal-terms library — see "Deferred /
      rolled-back work" above.
- [ ] (Eventually) collapse the 4 docx templates into a single master
      with conditional sections — also part of the deferred work.

## Things to NOT regress on (load-bearing decisions)

- **`price_per_user` is all-in.** Don't add hosting on top of it.
  Don't subtract hosting/credits before computing discount.
- **Discount is `(list - ppu) / list`.** Not `(list - effective platform
  per user) / list`. The simple form matches rep intuition and the
  routing banner.
- **`/quote-override` stays.** It's the escape hatch when buttons aren't
  an option (state ≠ pending, message buttons broken). The RevOps
  button-override added in `94f98b6` is supplementary, not a
  replacement.
- **`getAuthorization` returns `{ authorized, isOverride }`.** Callers
  use both — `isOverride` drives the `(override)` suffix on
  `decided_by_name`.
- **`deliverOrderForm` lives in `lib/orderForm.ts`** so both
  `interactivity.ts` (button click) and `quote-override.ts` /
  `quote-regenerate.ts` / `process-quote.ts` (slash commands +
  processor) share one implementation.
- **`Quote_Approval__c.Request_Id__c` is the unique external Id.**
  All upserts key off it. Don't introduce a different keying scheme.
