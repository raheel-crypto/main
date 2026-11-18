@isTest
private class RogoStandardTermsTest {

    private static final String TERMS = 'https://rogo.com/legal/terms-and-conditions';
    private static final String DPA = 'https://rogo.com/legal/data-processing-agreement';
    private static final String TRUST = 'https://trust.rogo.ai/';
    // The trust center's export: CRLF lines, a quoted comma, a doubled quote, a line break inside a value.
    private static final String SUBPROCESSORS = '"Company Name","Purpose","Location","Additional Details","Created At"\r\n'
        + '"Google Cloud","Cloud Services","United States","Privacy Portal: https://cloud.google.com/privacy","May 15, 2025"\r\n'
        + '"Deepgram","Speech-to-Text (Rogo Notes-only)","United States","Privacy: https://deepgram.com","October 8, 2026"\r\n'
        + '"Anthropic","Anthropic Enterprise LLM Inference API","United States","Privacy Portal:\n'
        + 'https://www.anthropic.com/legal/privacy","February 3, 2026"\r\n'
        + '"FoundryLabs, Inc. (E2B)","Ephemeral ""sandboxed"" compute","United States","","February 3, 2026"\r\n'
        + '\r\n';

    // The T&Cs redirect once; the DPA is a page with a date; the trust center is a
    // browser-rendered shell. Anything that is not a GET is the extraction reply.
    public class SiteMock implements HttpCalloutMock {
        public Integer termsStatus = 200;
        public Boolean fail = false;
        public Integer gets = 0;
        public List<String> endpoints = new List<String>();
        public String lastPost;
        public HttpResponse respond(HttpRequest req) {
            HttpResponse r = new HttpResponse();
            if (req.getMethod() == 'GET') {
                gets++;
                endpoints.add(req.getEndpoint());
                if (fail) throw new CalloutException('Unauthorized endpoint, please check Setup->Security->Remote site settings.');
                if (req.getEndpoint() == TERMS) {
                    r.setStatusCode(301);
                    r.setHeader('Location', '/legal/terms');
                    return r;
                }
                if (req.getEndpoint() == 'https://rogo.com/legal/terms') {
                    r.setStatusCode(termsStatus);
                    r.setBody(page('Terms &amp; Conditions', null,
                        '14. Term and Renewal. This Agreement renews automatically unless either party gives notice of '
                        + 'non-renewal at least thirty (30) days prior to the end of the then-current term.'));
                    return r;
                }
                if (req.getEndpoint() == DPA) {
                    r.setStatusCode(200);
                    r.setBody(page('Data Processing Agreement', 'Last Updated: May 5, 2026',
                        'Rogo shall give Customer at least thirty (30) days notice of any new Subprocessor.'));
                    return r;
                }
                r.setStatusCode(200);
                r.setBody('<html><body><div id="root"></div><script>app()</script></body></html>');
                return r;
            }
            lastPost = req.getBody();
            r.setStatusCode(200);
            r.setBody(JSON.serialize(new Map<String, Object>{
                'model' => 'claude-sonnet-5', 'stop_reason' => 'end_turn',
                'content' => new List<Object>{ new Map<String, Object>{ 'type' => 'text', 'text' => JSON.serialize(
                    new Map<String, Object>{ 'Type' => 'New Business', 'Documents' => new List<Object>{
                        new Map<String, Object>{ 'file' => 'FILE 1 (CURRENT DEAL): Order Form', 'group' => 'Current',
                            'class' => 'Order Form' } } }) } } }));
            return r;
        }
    }

    private static String page(String title, String dateLine, String clause) {
        return '<html><head><title>' + title + '</title><style>.x { color: red; }</style></head><body>'
            + '<script>var shell = "<p>not page text</p>";</script>'
            + '<h1>' + title + '</h1>' + (dateLine == null ? '' : '<p>' + dateLine + '</p>')
            + ('<p>' + clause + '</p>\n').repeat(20)
            + '<p>Use of &#8220;Marks&#8221; &sect;15</p></body></html>';
    }

    private static void configure(String urls) {
        OrderFormReviewer.settingsOverride = new Order_Form_Review_Setting__mdt(Mode__c = 'Shadow',
            Standard_Terms_URL__c = urls);
        RogoStandardTerms.fetchInTests = true;
        RogoStandardTerms.cached = null;
        RogoStandardTerms.subprocessorCsv = SUBPROCESSORS;
        RogoStandardTerms.subprocessorLoadedAt = Datetime.newInstanceGmt(2026, 11, 17, 15, 30, 0);
    }

    @isTest
    static void fetchesEveryDocumentAndKeepsOnlyTheText() {
        configure(TERMS + ' ' + DPA + '#annex-1 ' + TRUST);
        SiteMock mock = new SiteMock();
        Test.setMock(HttpCalloutMock.class, mock);
        RogoStandardTerms.Library lib = RogoStandardTerms.library();
        System.assertEquals(4, lib.docs.size(), 'three pages + the subprocessor list');

        RogoStandardTerms.Terms termsDoc = lib.docs[0];
        System.assert(termsDoc.ok(), termsDoc.failure);
        System.assertEquals('Terms & Conditions', termsDoc.name);
        System.assertEquals('https://rogo.com/legal/terms', termsDoc.finalUrl);
        System.assertEquals(null, termsDoc.lastUpdated);
        System.assert(termsDoc.text.startsWith('Terms & Conditions'), termsDoc.text.left(80));
        System.assert(termsDoc.text.contains('notice of non-renewal at least thirty (30) days'), termsDoc.text.left(300));
        String marks = String.fromCharArray(new List<Integer>{ 8220 }) + 'Marks' + String.fromCharArray(new List<Integer>{ 8221 });
        System.assert(termsDoc.text.contains(marks + ' §15'), termsDoc.text.right(80));
        System.assert(!termsDoc.text.contains('not page text') && !termsDoc.text.contains('color'), 'scripts and styles dropped');

        RogoStandardTerms.Terms dpaDoc = lib.docs[1];
        System.assert(dpaDoc.ok(), dpaDoc.failure);
        System.assertEquals(DPA, dpaDoc.url, 'the #fragment is not sent');
        System.assertEquals('Data Processing Agreement', dpaDoc.name);
        System.assertEquals('May 5, 2026', dpaDoc.lastUpdated);

        RogoStandardTerms.Terms trustDoc = lib.docs[2];
        System.assert(!trustDoc.ok());
        System.assertEquals('Trust Center (published subprocessor list)', trustDoc.name);
        System.assert(trustDoc.failure.contains('characters of text'), trustDoc.failure);

        String block = lib.promptBlock();
        System.assert(block.contains('=== ROGO TERMS & CONDITIONS'), block.left(400));
        System.assert(block.contains('=== ROGO DATA PROCESSING AGREEMENT'));
        System.assert(block.contains('Data Processing Agreement (' + DPA + '): fetched'));
        System.assert(block.contains('last updated May 5, 2026'));
        System.assert(block.contains('Trust Center (published subprocessor list) (' + TRUST + '): could not be fetched'));
        System.assert(block.contains('"By reference: <url>"'), 'a referenced subprocessor list stays by reference');
        System.assert(block.contains('=== ROGO SUBPROCESSOR LIST (https://trust.rogo.ai) ==='));
        List<String> lines = lib.sourceLines();
        System.assertEquals(4, lines.size());
        System.assert(lines[2].startsWith('NOT FETCHED: Rogo Trust Center'), lines[2]);
        System.assert(lines[3].startsWith('Rogo Subprocessor List (trust center export, Salesforce static resource '
            + 'RogoSubprocessors), loaded 2026-11-17 15:30 UTC, 4 entries, latest added October 8, 2026'), lines[3]);

        // Once per transaction.
        RogoStandardTerms.library();
        System.assertEquals(4, mock.gets, 'redirect + T&Cs page + DPA + trust center, then cached');
    }

    @isTest
    static void failuresAreRecordedNotThrown() {
        SiteMock mock = new SiteMock();
        Test.setMock(HttpCalloutMock.class, mock);

        configure(TERMS);
        mock.termsStatus = 404;
        RogoStandardTerms.Terms notFound = RogoStandardTerms.library().docs[0];
        System.assert(!notFound.ok());
        System.assert(notFound.failure.contains('HTTP 404'), notFound.failure);
        System.assert(RogoStandardTerms.library().promptBlock().contains('could not be fetched'));
        System.assert(RogoStandardTerms.library().sourceLines()[0].startsWith('NOT FETCHED'));

        configure(TERMS);
        mock.fail = true;
        System.assert(RogoStandardTerms.library().docs[0].failure.contains('Remote site'));

        configure(null);
        System.assert(RogoStandardTerms.library().skipped, 'no URL configured: nothing fetched or sent');
        System.assertEquals(null, RogoStandardTerms.library().promptBlock());
        System.assert(RogoStandardTerms.library().sourceLines().isEmpty());

        System.assertEquals('https://rogo.com/x', RogoStandardTerms.absolute('https://rogo.com/legal/terms', '/x'));
        System.assertEquals('https://www.rogo.com/t', RogoStandardTerms.absolute('https://rogo.com/a', 'https://www.rogo.com/t'));
        System.assertEquals('Service Level Agreement', RogoStandardTerms.nameFor('https://rogo.com/legal/service-level-agreement'));
        System.assertEquals('Privacy Policy', RogoStandardTerms.nameFor('https://rogo.com/legal/privacy-policy'));
    }

    @isTest
    static void subprocessorList_readsTheTrustCenterExport() {
        configure(TERMS);
        Test.setMock(HttpCalloutMock.class, new SiteMock());
        RogoStandardTerms.Terms subs = RogoStandardTerms.library().docs[1];
        System.assert(subs.ok(), subs.failure);
        System.assertEquals('Subprocessor List', subs.name);
        System.assertEquals(4, subs.entries);
        System.assertEquals('October 8, 2026', subs.lastUpdated, 'the latest "Created At", not the last row');
        System.assert(subs.text.startsWith('Rogo\'s subprocessors (4), as listed on the trust center '
            + '(https://trust.rogo.ai) and loaded into Salesforce on 2026-11-17.'), subs.text.left(200));
        System.assert(subs.text.contains('\n- Google Cloud | Purpose: Cloud Services | Location: United States | '
            + 'Additional Details: Privacy Portal: https://cloud.google.com/privacy | Added: May 15, 2025\n'), subs.text);
        System.assert(subs.text.contains('- Anthropic | Purpose: Anthropic Enterprise LLM Inference API | Location: '
            + 'United States | Additional Details: Privacy Portal: https://www.anthropic.com/legal/privacy | Added: '
            + 'February 3, 2026'), 'a line break inside a value is a space: ' + subs.text);
        System.assert(subs.text.contains('- FoundryLabs, Inc. (E2B) | Purpose: Ephemeral "sandboxed" compute | '
            + 'Location: United States | Added: February 3, 2026'), 'quoted comma, doubled quote, blank detail: ' + subs.text);
        String block = RogoStandardTerms.library().promptBlock();
        System.assert(block.contains('- Subprocessor List (https://trust.rogo.ai): the trust center\'s list as exported '
            + 'and loaded into Salesforce on 2026-11-17 UTC, 4 subprocessors, the latest added October 8, 2026.'), block.left(600));
        System.assert(block.contains('a later addition is not a finding about the extraction'));

        // Not the export: recorded, not thrown.
        RogoStandardTerms.cached = null;
        RogoStandardTerms.subprocessorCsv = 'just some text';
        RogoStandardTerms.Terms bad = RogoStandardTerms.library().docs[1];
        System.assert(!bad.ok());
        System.assert(bad.failure.contains('not the trust center\'s CSV export'), bad.failure);
        String badLine = RogoStandardTerms.library().sourceLines()[1];
        System.assert(badLine.startsWith('NOT FETCHED: Rogo Subprocessor List (trust center export'), badLine);

        System.assertEquals(Date.newInstance(2026, 9, 16), RogoStandardTerms.longDate('September 16, 2026'));
        System.assertEquals(Date.newInstance(2026, 9, 16), RogoStandardTerms.longDate('16 Sept 2026'));
        System.assertEquals(Date.newInstance(2026, 9, 16), RogoStandardTerms.longDate('2026-09-16'));
        System.assertEquals(null, RogoStandardTerms.longDate('soon'));
        List<List<String>> rows = RogoStandardTerms.parseCsv('a,b\nc,"d\n""e"" f"');
        System.assertEquals(2, rows.size());
        System.assertEquals('d\n"e" f', rows[1][1]);
    }

    @isTest
    static void notFetchedInOtherTestsUnlessAskedFor() {
        OrderFormReviewer.settingsOverride = new Order_Form_Review_Setting__mdt(Mode__c = 'Shadow',
            Standard_Terms_URL__c = TERMS);
        RogoStandardTerms.cached = null;
        System.assert(RogoStandardTerms.library().skipped);
        System.assertEquals(0, RogoStandardTerms.spentMs());
    }

    @isTest
    static void extractionSendsTheDocumentsAsACachedSystemBlock() {
        Opportunity opp = new Opportunity(Name = 'Terms In Extraction', StageName = '4 - Proposal', CloseDate = Date.today());
        insert opp;
        insert new ContentVersion(Title = 'Rogo Order Form', PathOnClient = 'Rogo Order Form.pdf',
            VersionData = Blob.valueOf('%PDF-1.4 fake'), FirstPublishLocationId = opp.Id);
        List<Id> docIds = new List<Id>();
        for (ContentDocumentLink l : [SELECT ContentDocumentId FROM ContentDocumentLink WHERE LinkedEntityId = :opp.Id]) {
            docIds.add(l.ContentDocumentId);
        }
        configure(TERMS + ' ' + DPA);
        SiteMock mock = new SiteMock();
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        OrderFormExtractionJob.buildExtraction(opp.Id, docIds);
        Test.stopTest();
        Map<String, Object> req = (Map<String, Object>) JSON.deserializeUntyped(mock.lastPost);
        List<Object> sys = (List<Object>) req.get('system');
        System.assertEquals(2, sys.size(), 'prompt + the documents');
        Map<String, Object> termsBlock = (Map<String, Object>) sys[1];
        String text = String.valueOf(termsBlock.get('text'));
        System.assert(text.startsWith('ROGO STANDARD TERMS'), text.left(80));
        System.assert(text.contains('=== ROGO DATA PROCESSING AGREEMENT'));
        System.assertNotEquals(null, termsBlock.get('cache_control'));
    }
}
