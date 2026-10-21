@isTest
public class DocxTextTest {

    // A minimal .docx: the body part, which is all DocxText reads.
    public static Blob docx(String bodyXml) {
        Compression.ZipWriter w = new Compression.ZipWriter();
        w.addEntry('[Content_Types].xml', Blob.valueOf('<?xml version="1.0" encoding="UTF-8"?><Types/>'));
        w.addEntry(DocxText.BODY_PART, Blob.valueOf(
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            + '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" '
            + 'xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006"><w:body>'
            + bodyXml + '</w:body></w:document>'));
        return w.getArchive();
    }

    private static String para(String text) {
        return '<w:p><w:r><w:t xml:space="preserve">' + text + '</w:t></w:r></w:p>';
    }

    @isTest
    static void readsParagraphsTablesAndAcceptedChanges() {
        String body = para('Order Form')
            + '<w:p><w:pPr><w:tabs><w:tab w:val="left" w:pos="720"/></w:tabs></w:pPr>'
            + '<w:r><w:t>Subscription </w:t></w:r><w:r><w:rPr><w:b/></w:rPr><w:t>Fee</w:t></w:r>'
            + '<w:r><w:tab/><w:t>$120,000</w:t></w:r></w:p>'
            + '<w:p/><w:p/><w:p/>'
            + '<w:tbl><w:tr><w:tc><w:tcPr/><w:p><w:r><w:t>Seats</w:t></w:r></w:p></w:tc>'
            + '<w:tc><w:p><w:r><w:t>25</w:t></w:r></w:p></w:tc></w:tr></w:tbl>'
            + '<w:p><w:r><w:t xml:space="preserve">Term: </w:t></w:r>'
            + '<w:del w:id="1"><w:r><w:delText>12</w:delText></w:r></w:del>'
            + '<w:ins w:id="2"><w:r><w:t>24</w:t></w:r></w:ins>'
            + '<w:moveFrom w:id="3"><w:r><w:t>moved away</w:t></w:r></w:moveFrom>'
            + '<w:r><w:instrText xml:space="preserve"> PAGE </w:instrText></w:r>'
            + '<w:r><w:t xml:space="preserve"> months &amp; renews</w:t></w:r><w:r><w:br/><w:t>Next line</w:t></w:r></w:p>'
            + '<w:p><w:r><mc:AlternateContent><mc:Choice Requires="wps"><w:txbxContent>' + para('Box text')
            + '</w:txbxContent></mc:Choice><mc:Fallback><w:txbxContent>' + para('Box text')
            + '</w:txbxContent></mc:Fallback></mc:AlternateContent></w:r></w:p>';

        String text = DocxText.read(docx(body), null);

        System.assertEquals(
            'Order Form\nSubscription Fee\t$120,000\n\nSeats | 25\nTerm: 24 months & renews\nNext line\nBox text',
            text, 'tab stops are not tabs, blank lines collapse, cells join on a row, deletions and moves drop out, '
                + 'a text box is read once');
    }

    @isTest
    static void unreadableFilesSaySo() {
        Compression.ZipWriter w = new Compression.ZipWriter();
        w.addEntry('notes.txt', Blob.valueOf('not Word'));
        List<Blob> files = new List<Blob>{ Blob.valueOf('plain bytes, not a zip'), w.getArchive(), docx(para('x'.repeat(500))) };
        List<String> expected = new List<String>{ 'not a readable Word file', 'not a readable Word file', 'too large to read in memory' };
        for (Integer i = 0; i < files.size(); i++) {
            try {
                DocxText.read(files[i], 100);
                System.assert(false, 'expected: ' + expected[i]);
            } catch (DocxText.DocxException e) {
                System.assert(e.getMessage().startsWith(expected[i]), e.getMessage());
            }
        }
    }

    // ===== Through the extractor =====

    private class CapturingMock implements HttpCalloutMock {
        String requestBody;
        public HttpResponse respond(HttpRequest req) {
            requestBody = req.getBody();
            Map<String, Object> fields = new Map<String, Object>{
                'Documents' => new List<Object>{ new Map<String, Object>{
                    'file' => 'FILE 1 (CURRENT DEAL): Order Form', 'group' => 'Current', 'class' => 'Order Form' } },
                'Contract_Start_Date' => '2026-01-01',
                'Contract_Length_Months' => 12,
                'Total_Contract_Value' => 120000
            };
            HttpResponse r = new HttpResponse();
            r.setStatusCode(200);
            r.setHeader('Content-Type', 'application/json');
            r.setBody(JSON.serialize(new Map<String, Object>{
                'id' => 'msg_test', 'type' => 'message', 'role' => 'assistant', 'model' => 'claude-sonnet-5',
                'content' => new List<Object>{ new Map<String, Object>{ 'type' => 'text', 'text' => JSON.serialize(fields) } },
                'stop_reason' => 'end_turn',
                'usage' => new Map<String, Object>{ 'input_tokens' => 100, 'output_tokens' => 200 }
            }));
            return r;
        }
    }

    private static Id attach(Id parentId, String fileName, Blob data) {
        ContentVersion cv = new ContentVersion(Title = fileName.substringBeforeLast('.'), PathOnClient = fileName,
            VersionData = data, FirstPublishLocationId = parentId);
        insert cv;
        return [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
    }

    @isTest
    static void extractorSendsAWordFileAsText() {
        Opportunity opp = new Opportunity(Name = 'Word Deal', StageName = '4 - Proposal', CloseDate = Date.today());
        insert opp;
        Blob file = docx(para('Rogo Order Form') + para('Subscription Fee: "Annual" $120,000 & up'));
        Id docId = attach(opp.Id, 'Order Form.docx', file);
        CapturingMock mock = new CapturingMock();
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        Order_Form_Extraction__c row = OrderFormExtractionJob.buildExtraction(opp.Id, new List<Id>{ docId });
        Test.stopTest();

        System.assertEquals('Success', row.Extraction_Status__c, row.Error_Message__c);
        System.assertEquals(false, row.Docs_Dropped__c, 'the Word file was sent, not skipped');

        // The request is valid JSON and carries the file's text as a plain-text document.
        Map<String, Object> req = (Map<String, Object>) JSON.deserializeUntyped(mock.requestBody);
        List<Object> content = (List<Object>) ((Map<String, Object>) ((List<Object>) req.get('messages'))[0]).get('content');
        String sent;
        Boolean labelled = false;
        for (Object o : content) {
            Map<String, Object> block = (Map<String, Object>) o;
            if (block.get('type') == 'text' && String.valueOf(block.get('text')).contains(OrderFormExtractionJob.WORD_NOTE)) labelled = true;
            if (block.get('type') != 'document') continue;
            Map<String, Object> source = (Map<String, Object>) block.get('source');
            System.assertEquals('text', source.get('type'));
            System.assertEquals('text/plain', source.get('media_type'));
            sent = (String) source.get('data');
        }
        System.assertEquals('Rogo Order Form\nSubscription Fee: "Annual" $120,000 & up', sent);
        System.assert(labelled, 'the file label says it is Word text');
    }

    @isTest
    static void extractorRecordsAWordFileItCannotRead() {
        Opportunity opp = new Opportunity(Name = 'Broken Word Deal', StageName = '4 - Proposal', CloseDate = Date.today());
        insert opp;
        Id broken = attach(opp.Id, 'Order Form.docx', Blob.valueOf('not really a docx'));
        Id empty = attach(opp.Id, 'Blank.docx', docx('<w:p/>'));

        Test.startTest();
        Order_Form_Extraction__c row = OrderFormExtractionJob.buildExtraction(opp.Id, new List<Id>{ broken, empty });
        Test.stopTest();

        System.assertEquals('No Document', row.Extraction_Status__c);
        System.assertEquals(true, row.Docs_Dropped__c);
        System.assert(row.Error_Message__c.contains('Order Form (Word file not a readable Word file'), row.Error_Message__c);
        System.assert(row.Error_Message__c.contains('Blank (Word file has no text)'), row.Error_Message__c);
    }
}
