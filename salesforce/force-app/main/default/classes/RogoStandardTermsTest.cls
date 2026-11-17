@isTest
private class RogoStandardTermsTest {

    private static final String URL = 'https://rogo.com/legal/terms-and-conditions';

    // Serves the terms page (after one relative redirect) for GETs; anything else is the extraction reply.
    public class SiteMock implements HttpCalloutMock {
        public Integer pageStatus = 200;
        public String pageBody = page();
        public Boolean fail = false;
        public Integer gets = 0;
        public String lastPost;
        public HttpResponse respond(HttpRequest req) {
            HttpResponse r = new HttpResponse();
            if (req.getMethod() == 'GET') {
                gets++;
                if (fail) throw new CalloutException('Unauthorized endpoint, please check Setup->Security->Remote site settings.');
                if (req.getEndpoint() == URL) {
                    r.setStatusCode(301);
                    r.setHeader('Location', '/legal/terms');
                    return r;
                }
                r.setStatusCode(pageStatus);
                r.setBody(pageBody);
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

    private static String page() {
        String clause = '<p>14. Term and Renewal. This Agreement renews automatically unless either party gives notice '
            + 'of non-renewal at least thirty (30) days prior to the end of the then-current term.</p>\n';
        return '<html><head><title>Terms</title><style>.x { color: red; }</style></head><body>'
            + '<script>var shell = "<p>not page text</p>";</script>'
            + '<h1>Terms &amp; Conditions</h1><p>Last Updated: October 1, 2026</p>'
            + clause.repeat(20)
            + '<p>Use of &#8220;Marks&#8221; &sect;15</p></body></html>';
    }

    private static void configure(String url) {
        OrderFormReviewer.settingsOverride = new Order_Form_Review_Setting__mdt(Mode__c = 'Shadow',
            Standard_Terms_URL__c = url);
        RogoStandardTerms.fetchInTests = true;
        RogoStandardTerms.cached = null;
    }

    @isTest
    static void fetchesFollowsRedirectAndKeepsOnlyTheText() {
        configure(URL);
        SiteMock mock = new SiteMock();
        Test.setMock(HttpCalloutMock.class, mock);
        RogoStandardTerms.Terms t = RogoStandardTerms.get();
        System.assert(t.ok(), t.failure);
        System.assertEquals('https://rogo.com/legal/terms', t.finalUrl);
        System.assertEquals('October 1, 2026', t.lastUpdated);
        System.assert(t.text.startsWith('Terms & Conditions'), t.text.left(80));
        System.assert(t.text.contains('notice of non-renewal at least thirty (30) days'), t.text.left(300));
        System.assert(t.text.contains('“Marks” §15'), t.text.right(80));
        System.assert(!t.text.contains('not page text') && !t.text.contains('color'), 'scripts and styles dropped');
        System.assert(t.promptBlock().contains('the CURRENT online version'), t.promptBlock().left(300));
        System.assert(t.promptBlock().contains('last updated October 1, 2026'));
        System.assert(t.sourceLine().contains('last updated October 1, 2026'), t.sourceLine());
        // Once per transaction.
        RogoStandardTerms.get();
        System.assertEquals(2, mock.gets, 'one redirect + one page, then cached');
    }

    @isTest
    static void failuresAreRecordedNotThrown() {
        SiteMock mock = new SiteMock();
        Test.setMock(HttpCalloutMock.class, mock);

        configure(URL);
        mock.pageStatus = 404;
        RogoStandardTerms.Terms notFound = RogoStandardTerms.get();
        System.assert(!notFound.ok());
        System.assert(notFound.failure.contains('HTTP 404'), notFound.failure);
        System.assert(notFound.promptBlock().contains('could not be fetched'), notFound.promptBlock());
        System.assert(notFound.sourceLine().startsWith('NOT FETCHED'), notFound.sourceLine());

        configure(URL);
        mock.pageStatus = 200;
        mock.pageBody = '<html><body><div id="root"></div><script>app()</script></body></html>';
        System.assert(RogoStandardTerms.get().failure.contains('characters of text'), RogoStandardTerms.get().failure);

        configure(URL);
        mock.fail = true;
        System.assert(RogoStandardTerms.get().failure.contains('Remote site'), RogoStandardTerms.get().failure);

        configure(null);
        System.assert(RogoStandardTerms.get().skipped, 'no URL configured: nothing fetched or sent');
        System.assertEquals(null, RogoStandardTerms.get().promptBlock());

        System.assertEquals('https://rogo.com/x', RogoStandardTerms.absolute('https://rogo.com/legal/terms', '/x'));
        System.assertEquals('https://www.rogo.com/t', RogoStandardTerms.absolute('https://rogo.com/a', 'https://www.rogo.com/t'));
    }

    @isTest
    static void notFetchedInOtherTestsUnlessAskedFor() {
        OrderFormReviewer.settingsOverride = new Order_Form_Review_Setting__mdt(Mode__c = 'Shadow', Standard_Terms_URL__c = URL);
        RogoStandardTerms.cached = null;
        System.assert(RogoStandardTerms.get().skipped);
        System.assertEquals(0, RogoStandardTerms.spentMs());
    }

    @isTest
    static void extractionSendsTheTermsAsACachedSystemBlock() {
        Opportunity opp = new Opportunity(Name = 'Terms In Extraction', StageName = '4 - Proposal', CloseDate = Date.today());
        insert opp;
        insert new ContentVersion(Title = 'Rogo Order Form', PathOnClient = 'Rogo Order Form.pdf',
            VersionData = Blob.valueOf('%PDF-1.4 fake'), FirstPublishLocationId = opp.Id);
        List<Id> docIds = new List<Id>();
        for (ContentDocumentLink l : [SELECT ContentDocumentId FROM ContentDocumentLink WHERE LinkedEntityId = :opp.Id]) {
            docIds.add(l.ContentDocumentId);
        }
        configure(URL);
        SiteMock mock = new SiteMock();
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        OrderFormExtractionJob.buildExtraction(opp.Id, docIds);
        Test.stopTest();
        Map<String, Object> req = (Map<String, Object>) JSON.deserializeUntyped(mock.lastPost);
        List<Object> sys = (List<Object>) req.get('system');
        System.assertEquals(2, sys.size(), 'prompt + terms');
        Map<String, Object> termsBlock = (Map<String, Object>) sys[1];
        System.assert(String.valueOf(termsBlock.get('text')).startsWith('ROGO STANDARD TERMS & CONDITIONS'));
        System.assertNotEquals(null, termsBlock.get('cache_control'));
    }
}
