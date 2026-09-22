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

## Close Opportunity from an agent

An agent-driven port of the `Close_Opportunity_Button` screen flow. Three
tools on the same MCP server, each rendering an HXL card:

| Tool | Apex | Card | What it does |
|---|---|---|---|
| Get Close Readiness | `GetCloseReadiness` | `closeReadinessCard` | Read-only. Header, signed-order-form check, checklist of the 27 Closed Won fields, buttons to start Won or Lost. |
| Submit Closed Won | `SubmitClosedWon` | `closeSubmissionCard` | Validates and previews without `confirm`; with `confirm=true` writes the finance and handoff fields, sets the Account references flag, sends the RevOps Slack, queues order form extraction. Does not stamp the stage (RevOps does), except Contract Restructure which closes directly. Requires a signed order form on the record. |
| Submit Closed Lost | `SubmitClosedLost` | `closeSubmissionCard` | Runs the AI loss analysis and previews without `confirm`; with `confirm=true` stamps Closed Lost with reasons, notes, LOB, prior stage, and AI fields. |

Shared logic lives in `OpportunityCloseService`; the Slack callout runs after
commit in `CloseWonNotificationJob`. Submissions are tagged with a new
`Agent` value on `CW_Submission_Source__c`. Blank tool inputs keep the values
already on the record, so the agent only asks for what is missing. The
signed-document check accepts both the `__signed` prefix the flow searches for
and the `signed__` prefix it renames uploads to.

Supporting metadata is generated from one field list by
`scripts/gen_close_metadata.py` so the Apex responses, Lightning Types,
widget schemas, renderers, and Agent Action schemas stay in sync.

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
  genAiFunctions/
    Get_Account_Summary/
      Get_Account_Summary.genAiFunction-meta.xml   # Agent Action wrapping the Apex invocable
      input/schema.json            # accountId
      output/schema.json           # the 15 response fields, list typed to the inner Apex class
  mcpServerDefinitions/
    HXLAccounts.mcpServerDefinition-meta.xml       # the hosted MCP server: tool + UI resource wiring
```

The MCP server definition is the piece that makes the card render. Its
`<resources>` entry exposes the Lightning Type as an MCP Apps UI resource
(`ui://widget/lightningType/c__getAccountSummary`), and the tool's
`<uiResource>` links the tool to it. Without that link the tool returns
plain JSON and the client narrates it as text. Creating the server in Setup
does not set this link, so deploy this file over the server after creating it.

The Agent Action is what the MCP Servers "Add Tools" picker lists. A bare
Apex invocable does not appear there until it is wrapped as an Agent Action.

How a request flows: an agent calls the MCP tool → the org runs
`GetAccountSummary.getAccountSummary` → the result envelope matches the
`getAccountSummary` Lightning Type → its renderer hands the fields to the
`accountSummaryCard` widget → the host paints it natively.

### Deploy order

Envelope types reference response types, renderers reference widgets, and the
server definition references everything, so deploy in this order. Production
orgs require Apex tests to run on deploy, hence the test flags.

```
cd ~/sf-visualizer/salesforce
sf project deploy start --source-dir force-app/main/default/objects
sf project deploy start --source-dir force-app/main/default/classes --test-level RunSpecifiedTests --tests GetAccountSummaryTest --tests OpportunityCloseServiceTest --tests GetCloseReadinessTest --tests SubmitClosedWonTest --tests SubmitClosedLostTest
sf project deploy start --source-dir force-app/main/default/uiWidgets
sf project deploy start --source-dir force-app/main/default/lightningTypes/getAccountSummaryResponse --source-dir force-app/main/default/lightningTypes/getCloseReadinessResponse --source-dir force-app/main/default/lightningTypes/submitClosedWonResponse --source-dir force-app/main/default/lightningTypes/submitClosedLostResponse
sf project deploy start --source-dir force-app/main/default/lightningTypes/getAccountSummary --source-dir force-app/main/default/lightningTypes/getCloseReadiness --source-dir force-app/main/default/lightningTypes/submitClosedWon --source-dir force-app/main/default/lightningTypes/submitClosedLost
sf project deploy start --source-dir force-app/main/default/genAiFunctions
sf project deploy start --source-dir force-app/main/default/mcpServerDefinitions
```

The last step updates the existing `HXLAccounts` server in place. After it,
refresh the connector in the client (in Claude, remove and re-add the
connector, or use its refresh tools option) so it picks up the UI resource.
Clients cache widget templates by resource URI, so if a later widget change
does not show up, copy the Lightning Type to a new name and point
`<resourceUri>` at it.

### Register the tool (Setup, one time)

Salesforce hosts the MCP server for you. Create one and add the Apex action
as a tool:

1. Setup → Quick Find → **MCP Servers** → **Salesforce Servers** tab →
   **Create Salesforce MCP Server**. Give it a name such as `Rogo Account Tools`.
2. On the server, **Add Server Assets** → **Add Tools** → pick the Apex action
   **Get Account Summary** → save.
3. Copy the server URL shown on the server page. Hosted servers follow the
   pattern `https://<my-domain>.my.salesforce.com/services/mcp/...`.

If **Get Account Summary** is not listed, confirm the `genAiFunctions` deploy
succeeded: Setup → Agentforce Assets → Actions should show it.

### Let Claude (or another client) log in

External clients authenticate with OAuth through an External Client App:

1. Setup → Quick Find → **External Client App Manager** → **New External Client App**.
2. Enable OAuth. Callback URL for Claude: `https://claude.ai/api/mcp/auth_callback`.
3. Scopes: **Access Model Context Protocol (mcp)**, **Manage user data via APIs (api)**,
   **Perform requests at any time (refresh_token, offline_access)**.
4. Under flow settings, require **PKCE** and enable **JSON Web Token (JWT)-based
   access tokens**.
5. Save, then open the app's settings and copy the **Consumer Key**. The consumer
   secret is optional for Claude when PKCE is on.

In Claude (claude.ai → Settings → Connectors → Add custom connector) paste the
server URL from the MCP server page, the consumer key as the OAuth client ID,
and the secret if you copied it. Complete the Salesforce login when prompted.
Then ask Claude to summarize an account by Id, for example
"Summarize account 001cv000017KYtuAAG". The response renders as the card.

### Verify the action shape from the org

```
sf api request rest '/services/data/v67.0/actions/custom/apex/GetAccountSummary'
```

The `outputs` array should list the fifteen response fields, with
`opportunities` showing `apexClass: GetAccountSummary$OpportunitySummary`.
