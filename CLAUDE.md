# SF Visualizer — Development Notes

## User Context
The developer is new to terminal/CLI workflows. Always provide full copy-paste commands when pushing updates.

## After Pushing Changes
When changes are pushed, ALWAYS provide the full command sequence to pull and restart:

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

Then refresh the browser at http://localhost:5173

## Environment Variables
When the user needs to edit `.env`, tell them to run:
```
open -a TextEdit ~/sf-visualizer/.env
```
Then save with Cmd+S.

## Stopping Servers
Remind the user to press `Ctrl+C` in each terminal window before restarting.

## Salesforce metadata (salesforce/)
- Every new custom field MUST ship with field-level security. A field deployed
  from metadata is invisible to everyone, admins included, until a permission
  set or profile grants it. Add the field to
  `force-app/main/default/permissionsets/Agent_Close_Tools.permissionset-meta.xml`
  (or a new permission set), deploy it with the field, and give the user the
  `sf org assign permset` command.
- Deploy order for the close tools: objects → customMetadata → permissionsets →
  classes → uiWidgets → response Lightning Types → envelope Lightning Types →
  genAiFunctions → (only if changed) mcpServerDefinitions, then reactivate the
  server and remove/re-add the connector in Claude.
- Any change to a widget body or renderer MUST bump `REV` in
  `salesforce/scripts/gen_close_metadata.py` (currently `2`), regenerate,
  `git rm` the previous widget and envelope Lightning Type folders, and
  redeploy through mcpServerDefinitions. The hosted MCP server caches the
  compiled widget by name and no redeploy, reactivation, or connector reset
  clears it. Say so in the deploy instructions every time the widgets change.
  Deploying the classes folder needs every test class listed, including
  `GetAccountSummaryTest`, or the coverage check fails.
- The signed order form upload page that the close cards link to is the Deal
  Portal's `/upload?opp=<Id>` page, hosted on Vercel at
  `https://quote-bot-portal.vercel.app` (repo `Rogo-Technologies/gtm-eng`:
  `apps/deal-portal/app/upload`, `components/SignedPaperUpload.tsx`; the
  ContentVersion write is the `signed_paper_upload` action in
  `apps/slack-agent-dealdesk/.agents/skills/slack-agent/api/portal/rpc.ts`,
  rules in `lib/signed-paper.ts`). The visualizer keeps a local-development
  copy at `/upload?opp=<Id>` (`UploadSignedOrderFormPage`, `/api/close-docs`).
  The cards get the URL from the `Agent_Close_Setting.Default` custom metadata
  record (`Upload_Page_URL__c`). Uploaded files are titled `signed__<name>`,
  the prefix the Slack quote bot and Tabs' document pickup key on.
