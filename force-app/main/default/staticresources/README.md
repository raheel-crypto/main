# Chart.js static resource

The stacked bar chart in `pgStageProgressChart` loads Chart.js from the
`ChartJs` static resource. The actual JS bundle is **not** committed to git
(it's a third-party file we don't want to vendor). Drop it in once before the
first deploy.

## One-time setup

1. Download Chart.js v4 UMD bundle:

   ```
   curl -L -o force-app/main/default/staticresources/ChartJs.js \
       https://cdn.jsdelivr.net/npm/chart.js@4/dist/chart.umd.min.js
   ```

2. Deploy along with the rest of the project:

   ```
   sf project deploy start --source-dir force-app/main/default
   ```

If you'd rather host the file inside Salesforce only (no local copy), upload
`chart.umd.min.js` manually as a Static Resource named **ChartJs** via Setup
→ Static Resources → New, and skip step 1.
