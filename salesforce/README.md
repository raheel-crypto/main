# Salesforce metadata (HXL widgets)

This folder is a Salesforce DX project that holds metadata deployed to the org,
separate from the visualizer app in `client/`, `server/`, and `mcp-server/`.

## Contents

```
salesforce/
  sfdx-project.json                      # SFDX project config (API version must match the org)
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

The widget bundle only defines the UI. The rest of the chain lives alongside it:

```
force-app/main/default/
  classes/
    GetAccountSummary.cls          # @InvocableMethod that builds the card data
    GetAccountSummaryTest.cls      # unit tests (required for production deploys)
  lightningTypes/
    getAccountSummaryResponse/
      schema.json                  # CLT: the invocable response fields (1:1 with the widget)
    getAccountSummary/
      schema.json                  # CLT: invocable-action envelope (actionName, isSuccess, outputValues)
      renderer.json                # points at @widget/c/accountSummaryCard, binds outputValues.<field>
```

How a request flows: an agent calls the MCP tool → the org runs
`GetAccountSummary.getAccountSummary` → the result envelope matches the
`getAccountSummary` Lightning Type → its renderer hands the fields to the
`accountSummaryCard` widget → the host paints it natively.

### Deploy order

The envelope type references the response type, and the renderer references
the widget, so deploy in this order. Production orgs require Apex tests to run
on deploy, hence the test flags on the first step.

```
cd ~/sf-visualizer/salesforce
sf project deploy start --source-dir force-app/main/default/classes --test-level RunSpecifiedTests --tests GetAccountSummaryTest
sf project deploy start --source-dir force-app/main/default/lightningTypes/getAccountSummaryResponse
sf project deploy start --source-dir force-app/main/default/lightningTypes/getAccountSummary
```

### Register the tool

After the deploy, create a custom MCP server in Setup (search Setup for
"MCP") and add the **Get Account Summary** Apex action as a tool. Connect an
MCP Apps compatible client to that server and ask it to summarize an account
by Id.

### Verify the action shape from the org

```
sf api request rest '/services/data/v67.0/actions/custom/apex/GetAccountSummary'
```

The `outputs` array should list the fifteen response fields, with
`opportunities` showing `apexClass: GetAccountSummary$OpportunitySummary`.
