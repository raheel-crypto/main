// =============================================================================
// Check that Salesforce can read Rogo's online Terms & Conditions
// =============================================================================
// The extractor and the reviewer fetch the page live (RogoStandardTerms) from
// the Standard Terms URL on the "Default" Order Form Review Setting. This fetches
// it once and prints what they would get: status, final URL, the last-updated
// date found, the size of the text, and its first and last lines. Read-only.
//
// "Unauthorized endpoint": the Rogo_Website / Rogo_Website_WWW Remote Site
// Settings are missing or the page redirects to another host - add that host.
// "only N characters of text": the page needs a browser to render; tell Claude.
//
// Run: sf apex run --target-org rogo --file scripts/apex/checkRogoTerms.apex
// =============================================================================

RogoStandardTerms.Terms t = RogoStandardTerms.get();
System.debug('--- URL: ' + t.url + (t.finalUrl == null ? '' : ' -> ' + t.finalUrl) + ' (' + t.spentMs + ' ms)');
if (!t.ok()) {
    System.debug('--- NOT USABLE: ' + (t.skipped ? 'no Standard Terms URL is set' : t.failure));
    return;
}
System.debug('--- Last updated found on the page: ' + (t.lastUpdated == null ? '(none)' : t.lastUpdated));
System.debug('--- Text: ' + t.text.length() + ' characters');
System.debug('--- Starts: ' + t.text.left(600));
System.debug('--- Ends: ' + t.text.right(400));
