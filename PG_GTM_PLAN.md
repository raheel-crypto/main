# PG Insights — GTM Associate Dashboard Plan

Status: **planning only — not yet built**. Capture questions, revisit when GTM
team is ready to define their metrics.

## Why a separate dashboard

GTM Associates do high-volume outbound and **book** opportunities, but they
don't own deals after handoff to AEs. Their attribution lives on the
opportunity's `Booked_By__c` (lookup) + `Booked_By_Role__c = 'GTM Associate'`,
not `OwnerId`. Stage-2+ progression is a measure of *their lead quality*, not
their execution — semantically different from the AE dashboard.

## Identifying GTMs in this org

Three candidate filters (verify with stakeholders before picking):

1. `User.Title LIKE '%GTM%'`
2. Distinct `Booked_By__c` values where `Booked_By_Role__c = 'GTM Associate'`
   (~400 such opps in the last 120 days — small set)
3. A dedicated `User.Pod__c` value, if one exists for GTMs

Recommendation: **union of (1) and (2)** for resilience — covers titled GTMs
plus anyone who's actually been booking under that role.

## Metric mapping

| AE dashboard | GTM equivalent |
|---|---|
| WoW/MoM Stage 2+ entered | WoW/MoM opps **booked** (filtered by `Booked_By__c` + role, dated by `CreatedDate`) |
| Stage 2+ Progress by quarter chart | Booked-by-quarter chart, with a second stack showing how many of those advanced to Stage 2+ |
| Top Performers by Pod | Top GTMs by booked count (probably no pod split — smaller team) |
| Individual Outreach (CW / QTD) | **Same component, filtered to GTM users** — biggest reuse |
| Conversion heatmap | Mostly N/A — GTMs don't progress deals |

### One genuinely new GTM widget

**Pass-through rate to Stage 2+.** Of the opps each GTM booked this quarter,
how many reached Stage 2+? This is the GTM's lead-quality signal. Source: the
`OpportunityHistory` mock-seam already in `PGInsightsController` — filter to
opps where `Booked_By__c = <gtm>` and intersect with the
`firstStage2PlusByOpp` map.

## Architecture

- New Lightning App Page **GTM Insights**, separate from the AE one.
- New parent LWC `pgGtmInsightsApp`.
- New Apex class `PGGtmInsightsController`.
- **Reuse** `pgKpiTile` directly. Refactor `pgIndividualOutreach` to take an
  `@api userIds` prop (or a `@api roleKey` that the parent resolves to a user
  set) so both dashboards can use it.
- Keep both controllers thin; common helpers (fiscal math, MTD proration,
  the `mockFirstStage2PlusByOpp` seam pattern) can move to a shared
  `PGInsightsCommon` class once the GTM controller exists and we see what's
  duplicated.

## Quota model evolution

`PG_Quota__c` extends cleanly. Two options:

- **Recommended:** add a `Booked_Goal__c` Number field. AE rows leave it blank
  and use `NB_Goal__c` / `Exp_Goal__c`; GTM rows leave NB/Exp blank and use
  `Booked_Goal__c`. No row-typing required.
- Alternative: add a `Role__c` picklist (`AE` / `GTM`), reuse `NB_Goal__c` as a
  generic count goal. More normalized but requires the controller to switch
  on role.

The recommended approach keeps the data model loose and lets each controller
read only what it cares about.

## Reusable components inventory

| Component | Reuse strategy |
|---|---|
| `pgKpiTile` | Reuse as-is. |
| `pgPacingKpis` | Copy + recolor. Hardcoded labels make a parameterized version awkward. |
| `pgStageProgressChart` | Copy. The stacked bars will represent different metrics. |
| `pgTopPerformers` | Copy. Different per-row metric (booked count, not Stage 2+). |
| `pgIndividualOutreach` | **Refactor to accept `@api userIds`.** Used by both. |
| `pgConversionHeatmap` | Not used in GTM dashboard. |
| `pgKpiTile` | Reuse as-is. |

## Open questions for stakeholders

1. **Identifying GTMs** — Title (`%GTM%`), historical bookers, dedicated Pod, or
   something else? Most reliable single source?
2. **NB vs Upsell for GTM** — do GTMs book Upsells, or only New Business? If
   only NB, collapse to one metric column.
3. **Headline metric** — is *opps booked* the top-of-page number, or *opps
   booked that advanced to Stage 2+*?
4. **Pass-through window** — pass-through % calculated on opps booked this
   quarter (small denominator early in quarter), or a trailing 90 days?
5. **Goals** — does the GTM team set per-rep quarterly quotas like AEs do, or
   is it a team-level number? Does that change the per-rep view?
6. **Outreach view** — is it useful to merge AE + GTM activity into one
   "all outbound" leaderboard somewhere, or always keep them separate?
7. **Page layout** — same Lightning page as the AE dashboard with a tab, or a
   distinct GTM Insights page (current recommendation)?

## Rough phasing when we build

1. Stakeholder Q&A → fill in unknowns above.
2. Schema check via MCP: confirm GTM identification approach against live
   `User.Title` and `Booked_By__c` data.
3. Refactor `pgIndividualOutreach` to take an `@api userIds` prop; update the
   AE dashboard to pass it explicitly. Tests stay green.
4. Build `PGGtmInsightsController` + minimum-viable LWC bundle (KPIs +
   booked-trend chart + per-rep table).
5. Add pass-through-rate widget once the basic counts feel right.
6. Add quota field + wire it in.

## Related files (existing AE dashboard)

- Apex: `force-app/main/default/classes/PGInsightsController.cls`
- LWCs: `force-app/main/default/lwc/pg{InsightsApp,PacingKpis,StageProgressChart,TopPerformers,IndividualOutreach,ConversionHeatmap,KpiTile}/`
- Custom object: `force-app/main/default/objects/PG_Quota__c/`
- Permission set: `force-app/main/default/permissionsets/PG_Insights_Test_Loader.permissionset-meta.xml`
