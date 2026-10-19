# Large-document extractor (off-platform)

Extracts order-form / MSA data from documents too large for Salesforce Apex.
Apex's async heap is 12 MB, so it can't process files bigger than ~10 MB (a
25 MB scan can't even be read). This script does those off-platform using the
Anthropic API with the files sent inline (up to ~22 MB of files per deal, inside the 32 MB request limit), then writes the result back through
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

- **Model** defaults to `claude-sonnet-5` (thinking disabled) to match the in-platform pipeline. Each file is sent with a `FILE n (CURRENT DEAL): <title>` label so the model can classify it (Order Form / MSA / MNDA / DPA / Other); a run with no order form is recorded as **No Order Form**.
  Override with `--model` if you change the Apex model.
- Deals whose usable files total about 4 MB or less (each file 4 MB or less) go
  through the normal Apex flow; this is only for the oversized tail. A row with
  `Docs_Dropped__c` checked lists what Apex left out in its notes ("too large",
  "dropped to fit size budget" or "dropped to fit memory").
- ZIP files (DocuSign "Complete_with_Docusign_..." envelopes) are opened and the
  PDFs / images inside are sent as their own files, labelled `<zip title> /
  <file name>`; DocuSign's certificate of completion (`Summary.pdf`) goes last.
  Nothing is written to disk, and each file's size is checked before it is read.
- Files are sent most relevant first (order form, DPA, agreements; a ZIP right
  behind an explicit order form), so when a deal's files do not all fit, the
  incidental ones are the ones left out.
- Anything over ~32 MB exceeds Anthropic's per-request PDF limit and is skipped —
  those need splitting first.
- A later full refresh in Salesforce can replace a row this script wrote when its
  own read ranks the same (it cannot see inside ZIPs or past 4 MB). Re-run the
  script for those deals after a full refresh.
- If you re-run an opp that already has a row, you'll get a second (newer) row;
  clean up with `scripts/apex/dedupeExtractions.apex` as usual.
