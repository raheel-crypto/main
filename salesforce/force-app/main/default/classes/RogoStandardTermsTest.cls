@isTest
private class RogoStandardTermsTest {

    private static final String TERMS = 'https://rogo.com/legal/terms-and-conditions';
    private static final String DPA = 'https://rogo.com/legal/data-processing-agreement';
    private static final String TRUST = 'https://trust.rogo.ai/';

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
    }

    @isTest
    static void fetchesEveryDocumentAndKeepsOnlyTheText() {
        configure(TERMS + ' ' + DPA + '#annex-1 ' + TRUST);
        SiteMock mock = new SiteMock();
        Test.setMock(HttpCalloutMock.class, mock);
        RogoStandardTerms.Library lib = RogoStandardTerms.library();
        System.assertEquals(3, lib.docs.size());

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
        List<String> lines = lib.sourceLines();
        System.assertEquals(3, lines.size());
        System.assert(lines[2].startsWith('NOT FETCHED: Rogo Trust Center'), lines[2]);

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
