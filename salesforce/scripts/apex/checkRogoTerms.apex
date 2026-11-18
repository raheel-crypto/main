// =============================================================================
// Check that Salesforce can read Rogo's published legal documents
// =============================================================================
// The extractor and the reviewer fetch them live (RogoStandardTerms) from the
// Standard Terms URLs on the "Default" Order Form Review Setting: the online
// T&Cs, DPA and SLA. This fetches them once and prints what they would get for
// each: status, final URL, the last-updated date found, the size of the text, and
// its first and last lines. Then the subprocessor list, in full. Read-only.
//
// The subprocessor list is the trust center's CSV export, kept in the static
// resource RogoSubprocessors. To update it when the trust center changes:
//   1. trust.rogo.ai > Subprocessors > download the list (CSV).
//   2. Salesforce Setup > Quick Find "Static Resources" > RogoSubprocessors >
//      Edit > Choose File (the CSV) > Save.
//   3. Run this script: the list should show the new entries.
// No deploy needed; the next extraction or review reads it.
//
// "Unauthorized endpoint": the host has no Remote Site Setting (Rogo_Website,
// Rogo_Website_WWW, Rogo_Trust_Center) or the page redirects to another host.
// "only N characters of text": the page needs a browser to render; tell Claude.
//
// Run: sf apex run --target-org rogo --file scripts/apex/checkRogoTerms.apex
// =============================================================================

RogoStandardTerms.Library lib = RogoStandardTerms.library();
if (lib.skipped) {
    System.debug('--- No Standard Terms URLs are set.');
    return;
}
System.debug('--- ' + lib.docs.size() + ' document(s), ' + lib.spentMs + ' ms in all');
for (RogoStandardTerms.Terms t : lib.docs) {
    System.debug('=== ' + t.name + ' | ' + t.url + (t.finalUrl == null || t.finalUrl == t.url ? '' : ' -> ' + t.finalUrl)
        + ' (' + t.spentMs + ' ms)');
    if (!t.ok()) {
        System.debug('    NOT USABLE: ' + t.failure);
        continue;
    }
    if (t.origin != null) {
        System.debug('    Uploaded to Salesforce ' + t.fetchedAt.format('yyyy-MM-dd') + ' | ' + t.entries
            + ' subprocessors | latest added ' + (t.lastUpdated == null ? '(no dates found)' : t.lastUpdated));
        for (String line : t.text.split('\n')) System.debug('    ' + line);
        continue;
    }
    System.debug('    Last updated: ' + (t.lastUpdated == null ? '(none found)' : t.lastUpdated) + ' | '
        + t.text.length() + ' characters');
    System.debug('    Starts: ' + t.text.left(400));
    System.debug('    Ends: ' + t.text.right(250));
}
