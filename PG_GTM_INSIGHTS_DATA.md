# GTM Insights — Data & Calculation Reference

What every number on the GTM Insights dashboard means, where it comes from,
and how it's calculated. Companion to `PG_INSIGHTS_DATA.md` (which covers
the AE dashboard).

---

## Universal definitions

### Who counts as a GTM Associate

An active Salesforce User is a "GTM" for dashboard purposes if all of:

- `User.IsActive = TRUE`
- `User.UserRole.Name = 'GTM Associate'`
- `User.Title = 'GTM Associate'`

Both the role and title checks are applied so a user has to be explicitly
labeled. There's no role-prefix exclusion needed (unlike AEs) because the
role name is exact.

### Attribution: booked, not owned

GTMs **book** opps; they don't typically own them after handoff. So
attribution everywhere on this dashboard is via `Opportunity.Booked_By__c`
(lookup to User), not `OwnerId`. The AE who eventually owns the deal is
irrelevant to GTM credit.

### What counts as a booked opportunity

`Opportunity.Type IN ('New Business', 'Pilot', 'Upsell')` AND
`Opportunity.Booked_By__c IN <gtm user set>`. NB and Upsell are not
displayed separately (the GTM team mostly books NB with some Upsell, and
they're tracked together).

`Renewal`, `Downsell`, `Contract Restructure`, `Debooking` are explicitly
excluded.

### "Qualified" (Stage 2+)

A booked opp is "qualified" if there is any `OpportunityHistory` row for
it where `StageName IN ('2 - Discovery', '3 - POV', '4 - Proposal',
'5 - Contracting', 'Closed Won')`. This is the same Stage 2+ definition
the AE dashboard uses.

`% Qualified` = `Qualified / Booked × 100` over the chosen window.

### Goals: re-use `PG_Quota__c`

GTM goals live on the same `PG_Quota__c` custom object the AEs use, on
the same per-User-per-Quarter rows:

- `NB_Goal__c` — count target (opps booked)
- `NB_Amount_Goal__c` — $ amount target

The `Exp_*` and `Exp_Amount_*` fields are not read for GTMs since they
don't split NB vs Upsell.

### `#` vs `$` toggle

Identical pattern to the AE dashboard's `# of opps` / `$ pipeline` toggle.
Every wrapper carries both shapes; the LWC picks which to render.

### % Qualified window toggle

The status panel and ranking table support two windows:

- **QTD** (default) — current fiscal quarter through today
- **Current Month** — first of this calendar month through today

The window determines the booking date filter and the goal proration:

```
prorated_goal = quarterly_goal × (days_elapsed_in_window / days_in_window)
```

For QTD the denominator is the full fiscal quarter (≈ 90-92 days). For
Current Month it's the full calendar month, so partial-month attainment
scales correctly.

The trend chart is unaffected by this toggle — it always shows the full
weekly buckets across the current quarter, or the last 6 fiscal quarters.

---

## Quarter Recap tab

### Status panel

**Question answered:** how is the GTM team pacing this quarter (or month)
on the headline metric?

**Five numbers** (each respects the # vs $ toggle):

- **Opps Booked** — count (or $) of opps where `Booked_By__c IN gtmUserIds`
  AND `Type IN dashboard types` AND `CreatedDate` in the window.
- **Qualified (Stage 2+)** — subset of booked opps that have ever reached
  Stage 2+ in `OpportunityHistory`. Not time-scoped on the qualification
  date; just "of those we booked in the window, how many have advanced."
- **% Qualified** — `Qualified / Booked × 100`. Displays `0%` (not N/A)
  when Booked is 0, since the metric is well-defined.
- **Goal (window)** — sum of `NB_Goal__c` (or `NB_Amount_Goal__c`) across
  all GTMs for current fiscal year + quarter, prorated by window.
- **Attainment** — `Booked / Goal × 100`. Shows `—` when no goal is set.

### Booked Trend chart

**Question answered:** is GTM booking accelerating or decelerating?

**Two views via in-card toggle:**

- **Per Week (this Q)** (default) — one bar per ISO week from quarter
  start through today.
- **By Quarter (last 6)** — fiscal-quarter buckets.

**Stacked bar composition:**

- Bottom (cyan-to-teal gradient): Qualified (Stage 2+) opps booked in the
  bucket.
- Top (violet-to-indigo gradient): Booked-but-not-yet-qualified opps.
- Stack total = total booked. Drawn above the bar so totals are visible
  without hovering. `#` mode shows integer counts; `$` mode shows
  `$1.2M / $120K` shorthand.

Goal line is omitted from this chart (per-week / per-quarter targets
aren't decomposed in `PG_Quota__c`).

### GTM Ranking

**Question answered:** which GTMs are leading this window, and what does
their pass-through rate say about lead quality?

**Columns** (each respects `#` vs `$`):

- Rank — by booked count desc (ties broken by booked amount).
- GTM — User name.
- Meeting Booked — count or $ of booked opps in the window.
- Qualified — Stage 2+ subset of the meetings booked.
- % Qualified — `Qualified / Booked × 100`, or `N/A` if Booked is 0.
- Goal — that GTM's `NB_Goal__c` or `NB_Amount_Goal__c`, prorated by
  the window selection.
- Attainment — `Booked / Goal × 100`, or `—` if no goal set.

Every active GTM appears in the ranking, even if they booked zero in the
window — their row is faded italic and tells you they're inactive for
the period (or new and ramping).

---

## Individual Outreach tab

Two side-by-side cards with colored bars per column. The right card is
**always Quarter to Date** so it's a stable reference. The left card has
a window dropdown in its header — pick one of:

- Current Week
- Prior Week
- Current Month
- Prior Month

(Full names rather than `CW` / `PW` so the labels don't get confused with
`Closed Won`.)

Apex `getIndividualOutreach(windowLabel)` accepts the short codes `CW`,
`PW`, `CM`, `PM`, and `QTD`; the LWC sends those internally based on the
dropdown selection. The right (QTD) card is hard-wired to `QTD`.

| Column | Source | Filters |
|---|---|---|
| OB Emails | `Task` | `TaskSubtype = 'Email'` AND `Status = 'Completed'` AND `NektarSender__c = 'Us'` AND `ActivityDate` in window |
| OB Calls | `Task` | `TaskSubtype = 'Call'` AND `Status = 'Completed'` AND `ActivityDate` in window (Nektar tagging is null on Call records in this org) |
| OB LinkedIn | `Task` | `TaskSubtype = 'Task'` AND `Subject LIKE '%Sales Navigator%'` AND `Subject LIKE '%Sent%'` AND `ActivityDate` in window |
| Meetings | `Event` | `NektarSender__c = 'Us'` AND `NektarStatus__c = 'completed'` AND `Meeting_Type__c IN ('Discovery', 'First Meeting')` AND `ActivityDate` in window |
| Total OB | computed | sum of the above four |

Same `Group rows by manager` toggle. Same bar colors per column.

---

## Caveats and shared infrastructure

- **OpportunityHistory test seam** — `PGGtmInsightsController.mockFirstStage2PlusByOpp`
  mirrors the AE controller's pattern. Apex tests inject a hand-crafted
  map because OpportunityHistory rows don't auto-create in this org's
  test context.
- **`PG_Quota__c` is shared** — same custom object as the AE dashboard,
  same User-lookup + Fiscal Year + Fiscal Quarter triplet. GTM rows
  populate only `NB_Goal__c` / `NB_Amount_Goal__c`. AE rows can populate
  Exp_*. A single user could have rows from both perspectives; the
  controllers don't conflict.
- **Outreach activity classifier** — same prospecting-vs-in-deal noise
  problem as the AE side. The activity counts here include all outbound
  Tasks the GTM owns, not just cold prospecting. See the AE caveat
  section for the long-term plan (LLM classifier on Task).
- **Deployment** — GTM dashboard ships in the same SFDX project as the
  AE one. Drop the `pgGtmInsightsApp` component onto a new App Page
  named "GTM Insights" in App Builder to expose it; the AE dashboard's
  App Page is unaffected.
