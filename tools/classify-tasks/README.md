# classify-tasks-prototype

One-off prototype that classifies Salesforce Task records into pipe-gen-
relevant categories using Claude Haiku 4.5. Output is a CSV that can be
hand-graded to validate accuracy before we wire LLM classification into
Apex on the PG Insights dashboard.

Categories: `Prospecting`, `Meeting Followup`, `In-Deal Reply`,
`Inbound Response`, `Internal`, `Other`.

## Setup

```
cd ~/sf-visualizer/tools/classify-tasks
npm install
export ANTHROPIC_API_KEY=sk-ant-...
```

## Pull a sample from Salesforce

The simplest path is the `sf` CLI. Adjust the WHERE clause to match the
universe you want to test (the example below grabs ~100 recent AE-owned
outbound emails):

```
cd ~/sf-visualizer
sf data query --target-org rogo \
  --query "SELECT Id, Subject, Description, Owner.Name, ActivityDate, TaskSubtype FROM Task WHERE TaskSubtype IN ('Email','Call','LinkedIn') AND NektarSender__c = 'Us' AND Status = 'Completed' AND ActivityDate = LAST_N_DAYS:30 LIMIT 100" \
  --result-format csv > tools/classify-tasks/tasks-sample.csv
```

If you want a sample biased toward likely-prospecting (so we can stress-test
the classifier against close-call cases), add filters like
`AND Account.Status__c = 'Prospect' AND Account.Open_NB__c = 0`.

## Classify

```
cd tools/classify-tasks
npm run classify -- tasks-sample.csv tasks-classified.csv
```

The script processes 5 rows in parallel and prints a category breakdown
when it finishes. The output CSV has every input column plus
`Classification`, `Confidence`, `Reason`.

## Hand-grade

Open `tasks-classified.csv` in a spreadsheet, sample 30 rows, label each
with what *you* think the category should be, compare to the LLM column.
If LLM agreement is roughly >85%, productionize the approach in Apex.
If lower, iterate the prompt in `classify.mjs` (the system prompt and
the in-context examples are the levers) and re-run.

## Cost

Haiku 4.5 input is about $1/MTok. A 100-task run is well under $0.05.
A full backfill of ~100k tasks/quarter would be roughly $10.

## Notes

- This script does not write back to Salesforce. It only reads CSV input
  and writes CSV output. Productionization (when we get there) is a
  separate Apex Queueable + Named Credential build.
- Description content is sent to the Anthropic API. Rogo has an
  enterprise agreement with Anthropic, so this is acceptable for
  prototype purposes; the production design should use the existing
  Named Credential rather than a raw API key.
