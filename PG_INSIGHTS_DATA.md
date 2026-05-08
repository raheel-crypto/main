# PG Insights — Data & Calculation Reference

What every number on the PG Insights dashboard means, where it comes from,
and how it's calculated. Use this when stakeholders ask "what's actually in
that bar?"

---

## Universal definitions

The same scoping rules apply across nearly every widget. They're listed once
here so the per-widget sections can stay focused on what's specific.

### Who counts as an AE

An active Salesforce User is an "AE" for dashboard purposes if all of:

- `User.IsActive = TRUE`
- `User.UserRole.Name` contains one of `BUYSIDE`, `IB1`, `IB2`, `MM`
  (case-insensitive substring match)
- `User.Title` does not contain `BDR` (case-insensitive). Untitled users
  with a matching role are included.

The pod a user belongs to is derived from their role name (first matching
token wins, evaluated in the order `BUYSIDE`, `IB1`, `IB2`, `MM`):

| Role name contains | Pod label |
|---|---|
| `BUYSIDE` | Buyside |
| `IB1` | IB1 |
| `IB2` | IB2 |
| `MM` | MM |

The previous `User.Pod__c` field is no longer used for dashboard scoping.

### What counts as a New Business or Expansion opportunity

- **New Business**: `Opportunity.Type IN ('New Business', 'Pilot')` —
  Pilots are pre-NB pipeline and roll up under New Business in every
  count / $ widget.
- **Expansion**: `Opportunity.Type = 'Upsell'`

`Renewal`, `Downsell`, `Contract Restructure`, `Debooking` are explicitly
excluded. The dashboard never references them.

### `#` vs `$` (count vs amount)

Quarter Recap has a global toggle at the top — `# of opps` (default) and
`$ pipeline`. Every widget on that tab honors the toggle:

- KPI panels (when enabled): NB / Expansion totals + deltas in count or
  formatted currency (`$120K`, `$1.2M`).
- Stage 2+ Progress chart: bar heights and goal line both swap. Y-axis
  ticks reformat to `$` shorthand.
- Stage 2+ Status panel and Top Performers cards: counts and prorated
  goals + attainment swap to amount-based equivalents.

The Apex always returns both shapes in the same payload; the LWC picks
which to render. Switching the toggle is instant — no Apex re-call.

Goals come from two parallel pairs of fields on `PG_Quota__c`:
`NB_Goal__c` / `Exp_Goal__c` for counts, `NB_Amount_Goal__c` /
`Exp_Amount_Goal__c` for $. AEs can have either or both; missing values
display as `0` for that mode without affecting the other.

### What counts as "AE-sourced"

`Opportunity.Booked_By_Role__c LIKE 'AE%'`. In practice this matches `AE -
ENT` and `AE - MM` (and any future `AE - <pod>` value). Excludes
`Integration`, `GTM Associate`, `CSM - *`, `GTM Strategy`. The filter is
applied to every Opportunity-driven widget; outreach activity widgets are
not scoped this way (they're about volume, not opportunity sourcing).

### "Reached Stage 2+"

An opportunity is considered to have "reached Stage 2+" if there is at least
one `OpportunityHistory` row for it where `StageName IN ('2 - Discovery',
'3 - POV', '4 - Proposal', '5 - Contracting', 'Closed Won')`.

The **first** such history row's `CreatedDate` is the date the opp "entered
Stage 2+". This handles deals that skip stages (e.g. Stage 1 → Stage 4
directly counts as having reached Stage 2+ on the date of the jump).

`Closed Lost` is intentionally not in the list — losing a deal isn't
progression.

`OpportunityHistory` is the source of truth, not the custom
`Stage_N_Start_Date__c` fields, because those fields are only populated on
~33% of opportunities in this org and never on `Stage_2_Start_Date__c`.

### Fiscal year and quarter

The dashboard reads `Organization.FiscalYearStartMonth` and computes fiscal
year/quarter from a date. Naming convention: a fiscal year is named for the
year in which it ends. So if the org's fiscal year starts in February,
April 2025 sits in `FY2026-Q1`.

If the fiscal year starts in January (calendar-aligned), `FY` matches the
calendar year.

### MTD proration

Goal-related widgets that show a "Goal (MTD)" prorate the quarterly goal
linearly by days elapsed:

```
mtdGoal = quarterlyGoal × (days_elapsed_in_quarter / total_days_in_quarter)
```

Where `days_elapsed_in_quarter` is inclusive of both today and the quarter
start, and `total_days_in_quarter` is inclusive of the quarter start and
quarter end. Example: in a 92-day quarter, day 23 prorates to ~25%.

### "Outbound" activity

A Task counts as outbound if `NektarSender__c = 'Us'`. The Nektar.ai
integration tags activity it ingested from the AE side. Manually-typed
Tasks may or may not have this set; the filter currently treats them as
non-outbound. See the open caveats section below — there is ongoing work
on a more accurate prospecting classifier.

A Task is "completed" if `Status = 'Completed'`.

---

## Quarter Recap tab

### Feature flag: WoW / MoM panels

The Week-over-Week and Month-over-Month panels are **hidden by default**.
To re-enable them, edit the Lightning App Page in App Builder, select the
PG Insights component, and check **Show Week/Month KPIs**. No redeploy
required. The panels and their Apex still ship with the package; only the
visibility is gated.

### Week-over-Week (WoW) panel

**Question answered:** how is AE-driven Stage 2+ pipeline pacing this week
vs the prior week?

**Three tiles + deltas:**

- New Business — count of opps that reached Stage 2+ this week, Type = New Business
- Expansion — same with Type = Upsell
- NB % of Total — `nbCount / (nbCount + expCount) × 100`

Each tile shows a delta vs the prior week. Green if direction is favorable
(higher counts, higher NB%), red if not.

**Filters:**

- AE owns the opp (`OwnerId IN :aeIds`)
- AE-sourced (`Booked_By_Role__c LIKE 'AE%'`)
- Type IN (`'New Business'`, `'Upsell'`)
- First Stage 2+ entry's `CreatedDate` falls in the window

**Window definition (rolling, not calendar-week-bounded):**

- This week = today minus 6 days through today (7-day window inclusive)
- Last week = today minus 13 days through today minus 7 days

The rolling 7-day window is locale-independent. It does not align to
Sunday-start or Monday-start week boundaries.

### Month-over-Month (MoM) panel

Identical structure to WoW but the window is calendar-month-bounded:

- This month = first of this calendar month through today
- Last month = full prior calendar month (1st through last day)

This means early in the month "this month" is a short partial period; the
delta compared to a full prior month is expected to be negative purely on
elapsed-time grounds. Read MoM with that caveat.

### AE Qualified Stage 2+ Progress chart

**Question answered:** how is the team pacing on Stage 2+ pipeline
creation? Two views available via an in-card toggle:

- **Per Week (this Q)** — default. One bar per ISO week starting at the
  current fiscal quarter start through today. No goal line (per-week
  targets aren't stored).
- **By Quarter (last 6)** — last 6 fiscal quarters. Goal line overlays
  the bars when at least one quarter in the window has quotas configured.

**Visualization:** stacked bar chart, one bar per bucket. NB stack on
bottom (cyan-to-navy gradient), Expansion stack on top (rose-to-burgundy).
Dashed dark goal line in quarter view; tooltip shows total and breakdown.

**Bucket value (count mode):** count of opps owned by an AE, AE-sourced
(`Booked_By_Role__c LIKE 'AE%'`), Type IN (`'New Business'`, `'Pilot'`,
`'Upsell'`), where the **first** OpportunityHistory entry to a Stage 2+
value falls in that bucket.

**Bucket value (amount mode):** same universe, summed `Opportunity.Amount`
instead of count.

**Quarter labels:** `FYxxxx-Qx` derived from
`Organization.FiscalYearStartMonth`.

**Week labels:** compact `M/d` (e.g. `5/4`).

**Goal line (quarter view only):** sum of `PG_Quota__c.NB_Goal__c +
Exp_Goal__c` across every AE for the matching fiscal year + quarter
(count mode), or `NB_Amount_Goal__c + Exp_Amount_Goal__c` (amount mode).
Quarters with no quota rows have a `0` goal point and the line dips —
acceptable since the quarter genuinely has no goal set.

### Stage 2+ Status panel (above the pod cards)

**Question answered:** how is the AE team doing this quarter overall?

**Four numbers:**

- AE NB Stage 2+ — total count of opps reaching Stage 2+ this fiscal
  quarter, Type = New Business
- AE Exp Stage 2+ — same with Type = Upsell
- Goal (MTD) — sum of `(NB_Goal__c + Exp_Goal__c)` across every AE's
  current-quarter `PG_Quota__c` row, prorated by days into quarter
- Attainment — `(NB + Exp) / Goal MTD × 100`

**Filters:** same universe as the chart, scoped to entries where the first
Stage 2+ history row's `CreatedDate >= startOfCurrentFiscalQuarter()`.

If no PG_Quota__c rows exist for the current quarter, Goal MTD is 0 and
Attainment is shown as 0%.

### Top Performers by Pod

**Question answered:** which reps are leading their pod this quarter?

**Layout:** four cards in a row, one per pod, each with its own gradient
header — Buyside (rose/pink), IB1 (indigo), IB2 (teal), MM (amber). On
medium screens the cards wrap to a 2×2 grid; on small screens they stack.
Each card shows pod-level totals at the top and the top 5 reps in that
pod below.

**Pod-level metrics (header of each card):**

- Total count = sum of NB + Expansion Stage 2+ this quarter for that pod's
  AEs
- Goal (MTD) = sum of every AE in that pod's `(NB_Goal__c + Exp_Goal__c)`
  for the current quarter, prorated. AEs without a quota row contribute 0.
- Attainment = `(total count) / (Goal MTD) × 100`. Shown in a pill on the
  header.

**Per-rep rows (top 5 in pod):**

- Counted opps = same Stage 2+ universe, attributed by `Opportunity.OwnerId`
- Per-rep goal = that AE's `(NB_Goal__c + Exp_Goal__c)` for the current
  quarter, prorated. AEs without a quota row see `0` and a `—` for
  attainment.
- Sort: total count desc; tiebreak by attainment % desc.
- Trimmed to top 5 per pod.

The sort by count (not attainment) was a deliberate choice — mixing
percent and count in one score gave nonsensical orderings when some reps
had goals set and others didn't.

---

## Individual Outreach tab

Two side-by-side cards: **Current Week (CW)** and **Quarter to Date (QTD)**.
Identical structure, different time windows.

### Group rows by manager

A checkbox at the top of the tab (`Group rows by manager`, default off)
toggles between two layouts:

- **Off (default):** flat per-AE rows sorted by Total OB descending.
- **On:** AEs grouped under their `User.Manager.Name`. Each group has
  a dark banner row with summed Email / Call / LinkedIn / Meeting / Total
  counts for that manager's team. AEs with no manager fall under a
  "No Manager" group. Groups are ordered by total team OB descending.

Useful for VP-level review where the team-level numbers matter more than
individual leaderboards.

### Outreach table (CW and QTD)

**Question answered:** which reps are doing the most outbound activity?

**Universe:** all AEs (`OwnerId IN :aeIds`). No AE-sourced or pod restriction
beyond the standard AE filter — this is about activity volume, not
opportunity sourcing.

**Time windows:**

- CW: `ActivityDate = THIS_WEEK` (Salesforce SOQL literal — locale-aware)
- QTD: `ActivityDate = THIS_FISCAL_QUARTER`

`ActivityDate` is the date the activity was scheduled / occurred. This is
what we want, vs `CompletedDateTime`, which gets re-stamped to "now"
whenever a Task's `Status` flips to `Completed` — meaning a Nektar
backfill or bulk reconciliation can re-stamp historical Tasks with today
and inflate the current-period count.

**Columns and source:**

| Column | Source | Filters |
|---|---|---|
| OB Emails | `Task` | `TaskSubtype = 'Email'` AND `Status = 'Completed'` AND `NektarSender__c = 'Us'` AND `ActivityDate` in window |
| OB Calls | `Task` | `TaskSubtype = 'Call'` AND `Status = 'Completed'` AND `ActivityDate` in window. **No Nektar filter** — Call records in this org have all Nektar fields null, so `TaskSubtype` alone identifies them. |
| OB LinkedIn | `Task` | `TaskSubtype = 'Task'` AND `Subject LIKE '%Sales Navigator%'` AND `Subject LIKE '%Sent%'` AND `ActivityDate` in window |
| Meetings | `Event` | `NektarSender__c = 'Us'` AND `NektarStatus__c = 'completed'` AND `Meeting_Type__c IN ('Discovery', 'First Meeting')` AND `ActivityDate` in window |
| Total OB | computed | sum of the above four |

**LinkedIn is filtered differently.** Sales Navigator integration writes
its activity as generic `Task` records (`TaskSubtype = 'Task'`, not
`'LinkedIn'`) and does not flow through Nektar, so neither the
`TaskSubtype = 'LinkedIn'` nor `NektarSender__c = 'Us'` filters apply.
Outbound is identified by the Subject containing both `Sales Navigator`
and `Sent`.

**Why Meetings is so narrow:** Events on an AE's calendar include
internal 1:1s, all-hands, customer reviews, deal-progression syncs,
canceled meetings, etc. The filter intentionally restricts to
top-of-funnel pipe-gen meetings that actually happened — Discovery and
First Meeting types with a `completed` Nektar status. A wider definition
inflated the count by an order of magnitude.

**Why no `CallType = 'Outbound'` filter:** the field exists but is null on
nearly all Call Tasks in this org — filtering on it returns ~0 results.

**Bars:** each numeric cell renders a colored bar whose width is
proportional to that column's max value across all rows shown:

```
bar_width_pct = (cell_value / column_max) × 100
```

Zero values render no bar. The leader in each column has a full-width bar.

**Sort:** click any column header to sort. Default sort is Total OB desc.

**Bar colors per column:** cyan (emails), purple (calls), magenta
(LinkedIn), green (meetings), blue (total).

---

## Conversion tab

### Conversion Rates heatmap

**Question answered:** at each stage transition, what fraction of *settled*
deals converted? Two view modes via an in-card toggle:

- **By AE** (default) — one row per AE. Manager column shown.
- **By Pod** — rows aggregated to pod level. Optional **Combine IB1 + IB2**
  checkbox collapses both IB pods into a single `IB` row.

**Math:** for each group and each transition X→Y:

```
conversion = reached[Y] / eligible[X]
```

Where `reached[N]` = count of opps where any `OpportunityHistory` row's
`StageName` rank is ≥ N (cumulative).

Where `eligible[X]` = count of opps that have *settled* the X→Y decision:
either advanced past X (max rank > X) or closed at exactly X without
advancing (max rank == X AND `Opportunity.IsClosed = TRUE`).

**This excludes still-open deals at exactly X.** A rep with deals
currently in Contracting and no Closed Won deals shows `N/A` for
Contracting → Closed Won, not 0% — the deals are still in flight, they
haven't decided yet.

**Stage rank map:**

| StageName | Rank |
|---|---|
| `1 - Demo` | 1 |
| `2 - Discovery` | 2 |
| `3 - POV` | 3 |
| `4 - Proposal` | 4 |
| `5 - Contracting` | 5 |
| `Closed Won` | 6 |

`Closed Lost` is absent. An opp with stages `{Demo, Closed Lost}` has max
rank 1 — it counts in the denominator for Demo→Discovery but never in the
numerator. Correct treatment: closed-lost-from-Demo did not progress.

**Stage skipping:** an opp that jumps Stage 1 → Stage 4 directly creates
two history rows (Demo and Proposal). Its max rank is 4, so it counts as
having "reached" stages 2 and 3 even though no history row exists at those
stages. Justified because the deal logically passed through them; the
alternative (counting only literal history rows) would under-count
skipping deals.

**Universe:**

- AE owns the opp
- Type IN ('New Business', 'Upsell')
- All-time (no date filter on history). The percentages drift slowly with
  new data.

**Note: the AE-sourced filter (`Booked_By_Role__c LIKE 'AE%'`) is
intentionally NOT applied here**, even though every other Opportunity-driven
widget uses it. Conversion is about what an AE does with the deals they
own; whether the deal was originally booked by an AE, an Integration
partner, or a GTM Associate doesn't change the rep's responsibility to
move it through stages. Pipeline-generation widgets care about sourcing,
the heatmap doesn't.

**Columns (5 transitions):**

- Demo → Discovery
- Discovery → POV
- POV → Proposal
- Proposal → Contracting
- Contracting → Closed Won

**Rows:** one per AE that has at least one opp ever reach Stage 1+. Sorted
by manager name (alphabetical), then by AE name (alphabetical).

**Cell coloring:**

| Conversion % | Cell color |
|---|---|
| ≥ 75% | green |
| 50-74% | lime |
| 30-49% | yellow |
| < 30% | red |
| `N/A` (no settled denominator) | faded gray |

The faded-gray `N/A` treatment is important — it lets you distinguish
"0% real conversion" from "no settled deals at that stage yet to convert"
at a glance.

**Drill-down popup:** click any cell to open a modal showing the
underlying deals that contributed to that cell's denominator. Each row
shows opportunity name, current stage, amount, close date, and a status
label — `Advanced` (green-tinted, in numerator), `Closed without
advancing` (in denominator but not numerator), or `Open at stage` (won't
appear unless backend filter logic is changed). Backed by a separate
`getHeatmapCellOpps` Apex method that takes the same `groupBy` and
`combineIB` settings the heatmap uses.

---

## Custom data we maintain

### `PG_Quota__c` (custom object)

One row per AE per fiscal quarter, holding their goals (count, $, or both):

| Field | Type | Notes |
|---|---|---|
| `User__c` | Lookup → User | The AE this quota applies to |
| `Fiscal_Year__c` | Number(4,0) | e.g. `2026` |
| `Fiscal_Quarter__c` | Number(1,0) | `1`–`4` |
| `NB_Goal__c` | Number(18,2) | New Business Stage 2+ **count** target for the quarter |
| `Exp_Goal__c` | Number(18,2) | Upsell Stage 2+ **count** target for the quarter |
| `NB_Amount_Goal__c` | Number(18,2) | New Business Stage 2+ **$ amount** target for the quarter |
| `Exp_Amount_Goal__c` | Number(18,2) | Upsell Stage 2+ **$ amount** target for the quarter |
| (Name) | AutoNumber | `PGQ-{0000}` |

Goal MTD = `(<count goals or amount goals>) × proration` where proration
is days into quarter / total days in quarter. The toggle on Quarter Recap
picks which pair of fields to read.

If a goal field is missing, the AE shows `0` for that goal and `—` (or
0%) for the matching attainment. The dashboard does not invent fallback
values.

---

## Caveats and known gaps

These are real limitations to flag when stakeholders ask "why is X like
that?"

**Outreach inflation by in-deal traffic.** The Task counts include any
outbound email/call/LinkedIn touch the AE owns within the window — not
just prospecting. Sample-grading a recent set of ~100 Tasks (filtered to
`Account.Account_Status__c = 'Prospect'` and `Account.Open_NB__c = 0`)
found roughly 1 in 13 was a true cold prospecting touch; the rest were
post-meeting follow-ups, in-deal replies, and inbound responses. There is
ongoing work to introduce an LLM-based `Activity_Class__c` classifier on
Task to give a clean prospecting count; until that ships, treat the
absolute outreach numbers as directional, not literal.

**CRM hygiene gap on `Account_Status='Prospect'` accounts.** During the
classifier exploration we found ~23% of Tasks against `Prospect`-status
accounts with `Open_NB__c = 0` were actually replies on an active deal
that simply hadn't been logged as an Open NB Opportunity yet. This is its
own metric worth surfacing eventually.

**OpportunityHistory in test context.** This org's Apex test context does
not auto-create `OpportunityHistory` rows on opp insert (verified
empirically; production has 800+ rows for the current quarter as expected).
The controller has a `@TestVisible` mock seam (`mockFirstStage2PlusByOpp`
and `mockStagesByOpp`) so tests can inject a hand-crafted history map
without depending on auto-creation. Production code path is untouched.

**Pod definition is role-name-based, not Pod__c.** AEs are grouped by
substring match on `User.UserRole.Name`. Users in the relevant role
hierarchies but with `Title` containing `BDR` are excluded. Users whose
role name doesn't match any of the four tokens are not considered AEs by
the dashboard.

**No conversion-heatmap date filter.** All-time scope means the
percentages move slowly and a long-departed rep stays on the heatmap
forever if their `User.IsActive` was flipped after they had pipeline.
Worth a "trailing 12 months" filter eventually.

**Outreach `THIS_WEEK` literal.** Salesforce's `THIS_WEEK` SOQL literal is
locale-aware and aligns to Sunday-start or Monday-start week boundaries
based on the running user's locale. The CW outreach window therefore
varies by viewer locale — a US user and a UK user will see different
"this week" cutoffs at the Sunday/Monday boundary. WoW pacing on the
Quarter Recap tab uses an explicit 7-day rolling window in Apex to avoid
this.
