# Large-document extractor (off-platform)

Extracts order-form / MSA data from documents too large for Salesforce Apex.
Apex's async heap is 12 MB, so it can't process files bigger than ~10 MB (a
25 MB scan can't even be read). This script does those off-platform using the
Anthropic **Files API** (good up to 32 MB), then writes the result back through
a Salesforce REST endpoint that runs the *same* field mapping as the in-platform
pipeline — so the `Order_Form_Extraction__c` it creates is identical to a normal
one.

Use it only for the stragglers the Apex pipeline flags as `too large` (see the
`No Document` worklist query). Everything else should keep going through Apex.

## One-time setup

1. Deploy the Apex side (from `salesforce/`):
   ```
   sf project deploy start \
     --metadata ApexClass:OrderFormExtractionJob \
     --metadata ApexClass:OrderFormExtractionRest \
     --metadata ApexClass:OrderFormExtractorTest \
     --target-org rogo \
     --test-level RunSpecifiedTests --tests OrderFormExtractorTest
   ```
2. Install the Python deps and set your Anthropic key:
   ```
   cd salesforce/scripts/large-doc-extractor
   pip install -r requirements.txt
   export ANTHROPIC_API_KEY=sk-ant-...
   ```
   Salesforce auth is taken from your `sf` CLI session (`--target-org`, default `rogo`).

## Usage

```
# dry run — prints the extracted JSON, writes nothing
python3 extract_large_docs.py 006V400000JY2pFIAT 006cv00000enYG2AAM

# for real — inserts the Order_Form_Extraction__c rows
python3 extract_large_docs.py --write 006V400000JY2pFIAT 006cv00000enYG2AAM
```

Pass the Opportunity Ids from the `too large` rows in your `No Document`
worklist. The script reads the same prompt the Apex pipeline uses
(`staticresources/OrderFormPrompt.txt`), so extraction stays consistent.

## Notes

- **Model** defaults to `claude-sonnet-4-6` to match the in-platform pipeline.
  Override with `--model` if you change the Apex model.
- Files 3–4 MB and under still belong in the normal Apex flow; this is only for
  the oversized tail.
- Anything over ~32 MB exceeds Anthropic's per-request PDF limit and is skipped —
  those need splitting first.
- If you re-run an opp that already has a row, you'll get a second (newer) row;
  clean up with `scripts/apex/dedupeExtractions.apex` as usual.
