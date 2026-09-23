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
| Get Close Readiness | `GetCloseReadiness` | `closeReadinessCard2` | Read-only. Header, signed-order-form check, a progress bar of Closed Won fields completed, the 27 fields grouped into "Needed" (expanded) and "Complete" (collapsed) accordion sections, buttons to start Won or Lost. |
| Submit Closed Won | `SubmitClosedWon` | `closeSubmissionCard2` | Validates and previews without `confirm`; with `confirm=true` writes the finance and handoff fields, sets the Account references flag, sends the RevOps Slack, queues order form extraction. Does not stamp the stage (RevOps does), except Contract Restructure which closes directly. Requires a signed order form on the record. |
| Submit Closed Lost | `SubmitClosedLost` | `closeSubmissionCard2` | Runs the AI loss analysis and previews without `confirm`; with `confirm=true` stamps Closed Lost with reasons, notes, LOB, prior stage, and AI fields. The preview offers loss-reason choice buttons: the AI recommendation first, then up to three common alternatives, then "Other reason". Each button sends a prompt that re-runs the preview with that reason. |

Shared logic lives in `OpportunityCloseService`; the Slack callout runs after
commit in `CloseWonNotificationJob`. Submissions are tagged with a new
`Agent` value on `CW_Submission_Source__c`. Blank tool inputs keep the values
already on the record, so the agent only asks for what is missing. The
signed-document check accepts both the `__signed` prefix the flow searches for
and the `signed__` prefix it renames uploads to (the upload page writes
`signed__`, the prefix the Slack quote bot and Tabs' document pickup use).

Fewer round trips:

- **LOB/Division defaults from the account.** Account Business Type predicts
  LOB almost one to one in this org (for example `private_equity` → Private
  Equity in 1,546 of 1,567 deals), so a blank LOB is filled from it, shown in
  the values table as "(suggested from account type)", and written on
  confirm. `other` is not mapped because it is too noisy. Both submission
  cards offer LOB buttons (suggestion first, then the five most common LOBs,
  then "More LOB options") whenever LOB was not set explicitly.
- **Loss reasons as buttons**, ordered by how often closed-lost deals use them
  in this org, with the AI recommendation first when there is one and a
  "Retry AI analysis" button when the analysis failed.
- **Every choice-button prompt** tells the agent to keep the other preview
  values and to ask for anything still missing in a single message.
- **Upload signed order form** opens the Deal Portal's upload page
  (`https://quote-bot-portal.vercel.app/upload?opp=<Id>`, Rogo SSO), which
  saves the dropped file to the opportunity as a `signed__` ContentVersion
  (the FirstPublishLocationId link) and tells the rep to check the deal again.
  Agents cannot carry a file through an MCP tool call, so this small page is
  the bridge. It lives in the `Rogo-Technologies/gtm-eng` repo: the page is
  `apps/deal-portal/app/upload` + `components/SignedPaperUpload.tsx`, and the
  Salesforce write is the `signed_paper_upload` action of the deal-desk Slack
  agent (`apps/slack-agent-dealdesk/.agents/skills/slack-agent/api/portal/rpc.ts`,
  rules in `lib/signed-paper.ts`), which already holds the org credential. The
  portal lets the opportunity owner or a portal admin upload, takes PDF, Word
  or image scans up to 3 MB, and does not post the Mark Closed Won card; the
  agent's confirm step notifies RevOps as before. The base URL lives in the
  `Agent_Close_Setting.Default` custom metadata record (`Upload_Page_URL__c`);
  blank falls back to the opportunity's Files list, which the card also offers
  as a secondary button. The visualizer keeps a local-development copy of the
  page (`server/src/routes/closeDocs.ts`,
  `client/src/pages/UploadSignedOrderFormPage.tsx`) for
  `http://localhost:5173/upload`.

The AI analysis runs in the background. The Claude callout inside the shared
`DealScoreAIController` can take longer than an MCP tool call is allowed to
run, so the tools never call it inline. The first Closed Lost preview starts
`CloseAiAnalysisJob` (a queueable) and returns at once with an "AI analysis
running" notice and a Refresh preview button; the job writes the AI fields to
the record and the next preview shows the recommendation. Closed Won queues
the win summary after the submit commits. Progress lives in a new text field,
`Opportunity.Agent_AI_Status__c` ("Running since …", "Failed …: reason",
blank on success). A failed run shows its reason and a Retry AI analysis
button, which calls Submit Closed Lost with `retryAi=true`. Field-level
security for this field (and `CW_Submission_Source__c`) comes from the
`Agent_Close_Tools` permission set; a field deployed from metadata has no
FLS for anyone until a permission set grants it, so assign it to every user
who closes deals from an agent.

The shared `DealScoreAIController` is now part of this project for one small
change: its Claude callout timeout is a public static, `calloutTimeoutMs`,
defaulting to the original 30 seconds. The background job raises it to the
Apex maximum of 120 seconds before calling in, so the analysis that used to
time out at 30 seconds can finish. The screen flow's behavior is unchanged.
Because the class is deployed from here, its own test class
(`DealScoreAIControllerTest`, already in the org) must be in the test list
of the classes deploy so coverage is computed.

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
sf project deploy start --source-dir force-app/main/default/customMetadata
sf project deploy start --source-dir force-app/main/default/permissionsets
sf org assign permset --name Agent_Close_Tools
sf project deploy start --source-dir force-app/main/default/classes --test-level RunSpecifiedTests --tests GetAccountSummaryTest --tests OpportunityCloseServiceTest --tests GetCloseReadinessTest --tests SubmitClosedWonTest --tests SubmitClosedLostTest --tests DealScoreAIControllerTest
sf project deploy start --source-dir force-app/main/default/uiWidgets
sf project deploy start --source-dir force-app/main/default/lightningTypes/getAccountSummaryResponse --source-dir force-app/main/default/lightningTypes/getCloseReadinessResponse --source-dir force-app/main/default/lightningTypes/submitClosedWonResponse --source-dir force-app/main/default/lightningTypes/submitClosedLostResponse
sf project deploy start --source-dir force-app/main/default/lightningTypes/getAccountSummary --source-dir force-app/main/default/lightningTypes/getCloseReadiness2 --source-dir force-app/main/default/lightningTypes/submitClosedWon2 --source-dir force-app/main/default/lightningTypes/submitClosedLost2
sf project deploy start --source-dir force-app/main/default/genAiFunctions
sf project deploy start --source-dir force-app/main/default/mcpServerDefinitions
```

The `2` on the close widgets and their envelope Lightning Types is the
`REV` constant in `scripts/gen_close_metadata.py`; see "Widget changes need
a new name" below for why it exists and when to bump it.

The last step updates the existing `HXLAccounts` server in place. After it,
do both of these, in order, or cards stop rendering:

1. Setup → MCP Servers → HXL-Accounts: deactivate, then activate again. The
   running server keeps the old tool-to-resource wiring until it restarts.
2. In Claude, remove the connector and add it back (a refresh is not enough).
   Claude caches the tool list and its UI resource links from the first
   connection.

### Widget changes need a new name

The hosted MCP server caches the compiled widget by name, and that cache
survives a widget redeploy, a server definition redeploy, a server
deactivate/activate, and a connector remove/re-add. In September 2026 the
"Upload signed order form" button was in the org's widget bundle (a
`sf project retrieve` proved it) and the Apex returned the portal URL, yet
four full resets still rendered the previous button. The only reliable fix is
a name the server has never seen.

So: whenever a widget body or a renderer changes, bump `REV` in
`scripts/gen_close_metadata.py`, run the script, `git rm` the previous
`uiWidgets/closeReadinessCard<old>`, `uiWidgets/closeSubmissionCard<old>`,
and `lightningTypes/getCloseReadiness<old>`, `submitClosedWon<old>`,
`submitClosedLost<old>` folders, then deploy widgets → response types →
envelope types → server definition, and do the two reset steps above. The
response Lightning Types and the Agent Actions keep their names; only the
presentation layer moves. The old bundles stay in the org unused; delete them
from Setup when convenient. A change that only touches Apex or the response
field list does not need a bump, but adding a field does (the widget schema and
renderer change with it).

### If a card shows "Loading…" forever or "Couldn't render a rich UI"

The card iframe is a generic Salesforce template. It shows "Loading…" until
the tool result arrives with the hydrated widget definition in its `_meta`
block (`salesforce/uiMetadata`). When that block is missing the server
returned data but skipped the widget, which is what happens after a server
redeploy until it is reactivated and the connector is re-added (see above).
To see the raw server response, run the probe with the server URL from Setup:

```
cd ~/sf-visualizer/salesforce
python3 scripts/mcp_probe.py "PASTE_SERVER_URL_HERE" GetCloseReadinessapex_GetCloseReadiness '{"inputs":[{"opportunityId":"006cv00000kSCgTAAW"}]}'
```

It prints whether `salesforce/uiMetadata` is present and saves the full
result to `mcp_probe_last_result.json`.

### Register the tool (Setup, one time)

Salesforce hosts the MCP server for you. Create one and add the Apex action
as a tool:

1. Setup → Quick Find → **MCP Servers** → **Salesforce Servers** tab →
   **Create Salesforce MCP Server**. Give it a name such as `Rogo Account Tools`.
2. On the server, **Add Server Assets** → **Add Tools** → pick the Apex action
   **Get Account Summary** → save.
3. Copy the server URL shown on the server page. Custom hosted servers follow
   the pattern `https://api.salesforce.com/platform/mcp/v1/custom/<ServerApiName>`;
   this project's server is `.../custom/HXLAccounts`.

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
