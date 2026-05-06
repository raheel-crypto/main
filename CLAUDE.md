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

## PG Insights LWC (force-app/)

The `force-app/` folder is a separate Salesforce DX project for the **PG
Insights** Lightning Web Component (lives in the same git repo, but deploys
to Salesforce, not the local web servers above).

### One-time: install the Salesforce CLI

```
brew install --cask sf
```

Then log in to the Rogo org (browser will open):

```
sf org login web --alias rogo
```

### One-time: drop Chart.js into the static resource

```
cd ~/sf-visualizer
curl -L -o force-app/main/default/staticresources/ChartJs.js \
    https://cdn.jsdelivr.net/npm/chart.js@4/dist/chart.umd.min.js
```

### Deploy the LWC + Apex to Salesforce

```
cd ~/sf-visualizer
sf project deploy start --source-dir force-app/main/default --target-org rogo
```

### Run the Apex tests

```
cd ~/sf-visualizer
sf apex run test --tests PGInsightsControllerTest --target-org rogo --result-format human --wait 10
```

### Add the component to a Lightning page

After deploy, in Salesforce Setup:

1. Setup → **Lightning App Builder** → **New** → App Page → "PG Insights"
2. Drag the **PG Insights** component from the left panel onto the page
3. Save → Activate → choose the sales profiles that should see it
