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
- The signed order form upload page lives in the visualizer at `/upload?opp=<Id>`
  (client page `UploadSignedOrderFormPage`, server route `/api/close-docs`). The
  cards get its URL from the `Agent_Close_Setting.Default` custom metadata record
  (`Upload_Page_URL__c`), so a hosted deployment only needs that value changed.
