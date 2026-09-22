# Salesforce metadata (HXL widgets)

This folder is a Salesforce DX project that holds metadata deployed to the org,
separate from the visualizer app in `client/`, `server/`, and `mcp-server/`.

## Contents

```
salesforce/
  sfdx-project.json                      # SFDX project config (API 68.0)
  force-app/main/default/uiWidgets/
    accountSummaryCard/
      accountSummaryCard.json            # widget envelope + UEM tree (tile/* blocks)
      schema.json                        # input contract ({!$attrs.X} bindings)
      accountSummaryCard.uiwidget-meta.xml  # UiWidgetBundle registration
```

## Account Summary Card

An HXL (Headless Experience Layer) widget that renders an account overview in
any MCP Apps compatible host (Agentforce, Claude, ChatGPT, Slack, Rogo, and so
on). It expects the flat attribute set defined in `schema.json`:

| Attribute | Type | Notes |
|---|---|---|
| `accountName` | text | Card heading |
| `industry` | text | Caption under the heading |
| `type` | text | Rendered as a badge (Customer, Prospect, ...) |
| `ownerName` | text | |
| `billingLocation` | text | Pre-formatted, e.g. `San Francisco, CA` |
| `website` | text | |
| `annualRevenue` | text | Pre-formatted currency string |
| `numberOfEmployees` | number | |
| `contactCount` | number | |
| `openOpportunityCount` | number | |
| `openPipelineAmount` | text | Pre-formatted currency string |
| `hasOpenOpportunities` | boolean | Shows the opportunity list |
| `isPipelineEmpty` | boolean | Shows the empty-state callout |
| `opportunities` | list of `{ name, stageName, amount, closeDate }` | Top open opportunities |
| `accountUrl` | text | Target of the "Open in Salesforce" button |

Currency and date values are passed pre-formatted because tile blocks render
strings as-is and the widget expression language has no formatting functions.

## Deploying

Install the Salesforce CLI once:

```
npm install -g @salesforce/cli
```

Log in to the org (opens a browser):

```
cd ~/sf-visualizer/salesforce
sf org login web --alias rogo --set-default
```

Deploy the widget:

```
cd ~/sf-visualizer/salesforce
sf project deploy start --source-dir force-app/main/default/uiWidgets
```

Check what is deployed:

```
sf project retrieve preview
```

## Wiring the widget to an MCP tool

The bundle only defines the UI. To make it appear when an agent calls a tool,
the org also needs:

1. An Apex class with an `@InvocableMethod` that returns the fields above.
2. A custom MCP server in Setup that exposes that invocable action as a tool.
3. Two object-based Custom Lightning Types under `lightningTypes/` (one for the
   response fields, one for the invocable-action envelope) plus a
   `renderer.json` in the envelope type that points at
   `@widget/c/accountSummaryCard` and binds each attribute from
   `{!$attrs.outputValues.<field>}`.

Those pieces are not in this folder yet.
