@isTest
private class OrderFormLinesTest {

    // Closed Won opportunities are inserted directly: grant the Bypass_Validations
    // custom permission in its own transaction (as the other order form tests do).
    @testSetup
    static void grantValidationBypass() {
        List<CustomPermission> perms = [
            SELECT Id FROM CustomPermission WHERE DeveloperName = 'Bypass_Validations' LIMIT 1
        ];
        if (perms.isEmpty()) return;
        PermissionSet ps = new PermissionSet(Name = 'Lines_Test_Bypass', Label = 'Lines Test Bypass');
        insert ps;
        insert new SetupEntityAccess(ParentId = ps.Id, SetupEntityId = perms[0].Id);
        insert new PermissionSetAssignment(AssigneeId = UserInfo.getUserId(), PermissionSetId = ps.Id);
    }

    private static Map<String, Object> line(String product, String label, Object quantity, Object unitPrice,
                                            Object amount, String basis) {
        return new Map<String, Object>{ 'product' => product, 'label' => label, 'quantity' => quantity,
            'unit_price' => unitPrice, 'amount' => amount, 'basis' => basis };
    }

    @isTest
    static void productsAndAnnualAmounts() {
        List<OrderFormLines.Line> lines = OrderFormLines.parse(new List<Object>{
            line('Platform Fee', null, 25, null, 69000, 'per year'),
            line(null, 'Credit Commitment', 2300000, null, 46000, 'Annual'),
            line('Hosting Fee', null, null, null, 1000, 'per quarter'),
            line(null, 'CRM Integration Cost', null, null, 4000, 'one-time'),
            line('Rogo Notes', null, 5, 100, null, 'per license per month'),
            line(null, 'Complimentary Credits', 50000, null, null, null),
            line('Other', 'Market data', null, null, 24000, 'for the Subscription Period'),
            'not a line'
        }, 24);

        System.assertEquals(7, lines.size(), 'Anything that is not a line is skipped');
        System.assertEquals('Rogo Seats', lines[0].product);
        System.assertEquals(69000, lines[0].annualAmount);
        System.assertEquals('Paid Credits', lines[1].product);
        System.assertEquals('Hosting', lines[2].product);
        System.assertEquals(4000, lines[2].annualAmount, 'per quarter x 4');
        System.assertEquals('Professional Services', lines[3].product);
        System.assertEquals(false, lines[3].recurring);
        System.assertEquals(null, lines[3].annualAmount);
        System.assertEquals('Arvo Seats', lines[4].product);
        System.assertEquals(6000, lines[4].annualAmount, '100 x 5 x 12');
        System.assertEquals('Free Credits', lines[5].product);
        System.assertEquals(null, lines[5].annualAmount, 'No price of their own');
        System.assertEquals('Other', lines[6].product);
        System.assertEquals(12000, lines[6].annualAmount, '24,000 for the 24-month term x 12/24');

        System.assertEquals(69000 + 46000 + 4000 + 6000 + 12000, OrderFormLines.recurringAnnual(lines));
        System.assertEquals(6000 + 12000, OrderFormLines.annualFor(lines, OrderFormLines.OTHER_RECURRING));
        System.assertEquals(5, OrderFormLines.seatsAt(lines, 100));
        System.assertEquals(0, OrderFormLines.parse(null, 12).size());
        System.assertEquals(0, OrderFormLines.fromJson('not json').size());
        System.assertEquals(null, OrderFormLines.toJson(new List<OrderFormLines.Line>()));
    }

    private static Order_Form_Extraction__c split(Decimal seats, Decimal seatFee, Decimal commitFee, Decimal credits,
                                                  String period, Decimal freeCredits) {
        return new Order_Form_Extraction__c(Type__c = 'New Business', Value_Basis__c = 'Annual', Seat_Licenses__c = seats,
            License_Fees__c = seatFee, Credit_Commit_Fee__c = commitFee, Credits_Purchased__c = credits,
            Credits_Period__c = period, Free_Credits__c = freeCredits);
    }

    @isTest
    static void linesFollowTheSeatFeeAndCreditSplit() {
        // Peel Hunt read as one seats line holding seats + credits.
        List<OrderFormLines.Line> bundled = OrderFormLines.parse(new List<Object>{
            line('Rogo Seats', 'Platform Fee', 25, null, 115000, 'Annual') }, 12);
        List<String> notes = OrderFormLines.alignWith(bundled, split(25, 69000, 46000, 2300000, 'contract', null), 12);
        System.assertEquals(2, bundled.size());
        System.assertEquals(69000, bundled[0].amount, 'The seat fee');
        System.assertEquals('Paid Credits', bundled[1].product);
        System.assertEquals(2300000, bundled[1].quantity);
        System.assertEquals(46000, bundled[1].annualAmount, 'The credit commitment');
        System.assertEquals(115000, OrderFormLines.recurringAnnual(bundled));
        System.assertEquals(2, notes.size());

        // Credits that come with the seats: no price of their own; free credits added.
        List<OrderFormLines.Line> included = OrderFormLines.parse(new List<Object>{
            line('Rogo Seats', 'Platform Fee', 30, null, 90000, 'Annual'),
            line('Paid Credits', 'Credit Allocation', 3000000, null, null, null) }, 12);
        OrderFormLines.alignWith(included, split(30, 90000, null, 3000000, 'year', 100000), 12);
        System.assertEquals('Included Credits', included[1].product);
        System.assertEquals(null, included[1].annualAmount);
        System.assertEquals('Free Credits', included[2].product);
        System.assertEquals(100000, included[2].quantity);
        System.assertEquals(90000, OrderFormLines.recurringAnnual(included));

        // Nothing listed: seats and credits come from the extraction's fields.
        List<OrderFormLines.Line> none = new List<OrderFormLines.Line>();
        OrderFormLines.alignWith(none, split(25, 69000, 46000, 2300000, 'contract', null), 12);
        System.assertEquals(2, none.size());
        System.assertEquals(115000, OrderFormLines.recurringAnnual(none));

        // An Arvo-only paper: its seats are the Arvo line, no Rogo seats are added.
        List<OrderFormLines.Line> arvo = OrderFormLines.parse(new List<Object>{
            line('Arvo Seats', 'Licenses', 20, 100, null, 'Monthly') }, 12);
        OrderFormLines.alignWith(arvo, split(20, null, null, null, null, null), 12);
        System.assertEquals(1, arvo.size());
    }

    @isTest
    static void realignFixesLinesReadBeforeTheSplit() {
        // Lines backfilled before the alignment: one seats line holding seats + credits.
        Opportunity opp = new Opportunity(Name = 'Realign', StageName = '4 - Proposal', CloseDate = Date.today());
        insert opp;
        Order_Form_Extraction__c row = new Order_Form_Extraction__c(Opportunity__c = opp.Id, Extraction_Status__c = 'Success',
            Type__c = 'New Business', Value_Basis__c = 'Annual', Seat_Licenses__c = 25, License_Fees__c = 69000,
            Credit_Commit_Fee__c = 46000, Credits_Purchased__c = 2300000, Credits_Period__c = 'contract',
            Annual_Recurring_Revenue__c = 115000, Contract_Length_Months__c = 12, Lines_Read_At__c = System.now(),
            Line_Items__c = OrderFormLines.toJson(OrderFormLines.parse(new List<Object>{
                line('Rogo Seats', 'Platform Fee', 25, null, 115000, 'Annual') }, 12)));
        insert row;
        System.assertEquals(1, [SELECT COUNT() FROM Order_Form_Line__c WHERE Extraction__c = :row.Id]);

        List<Order_Form_Extraction__c> changes = OrderFormExtractionJob.realignLines(new Set<Id>{ row.Id });
        System.assertEquals(1, changes.size());
        update changes;

        Order_Form_Extraction__c after = [SELECT Lines_Recurring_Annual__c, Lines_Mismatch__c, Lines_Read_At__c
                                          FROM Order_Form_Extraction__c WHERE Id = :row.Id];
        System.assertEquals(115000, after.Lines_Recurring_Annual__c);
        System.assertEquals(false, after.Lines_Mismatch__c);
        List<Order_Form_Line__c> lines = [SELECT Product__c, Amount__c FROM Order_Form_Line__c
                                          WHERE Extraction__c = :row.Id ORDER BY Line_Number__c];
        System.assertEquals(2, lines.size(), 'Replaced with the split, not added to');
        System.assertEquals(69000, lines[0].Amount__c);
        System.assertEquals('Paid Credits', lines[1].Product__c);
        System.assertEquals(0, OrderFormExtractionJob.realignLines(new Set<Id>{ row.Id }).size(), 'Nothing left to change');
    }

    @isTest
    static void triggerKeepsLineRecordsInStep() {
        Opportunity opp = new Opportunity(Name = 'Lines Sync', StageName = '4 - Proposal', CloseDate = Date.today());
        insert opp;
        Order_Form_Extraction__c row = new Order_Form_Extraction__c(Opportunity__c = opp.Id, Extraction_Status__c = 'Success',
            Line_Items__c = OrderFormLines.toJson(OrderFormLines.parse(new List<Object>{
                line('Rogo Seats', 'Platform Fee', 10, null, 50000, 'Annual'),
                line('Arvo Seats', 'Arvo', 20, 100, null, 'Monthly') }, 12)));
        insert row;

        List<Order_Form_Line__c> created = [
            SELECT Product__c, Quantity__c, Annual_Amount__c, Recurring__c, Line_Number__c
            FROM Order_Form_Line__c WHERE Extraction__c = :row.Id ORDER BY Line_Number__c
        ];
        System.assertEquals(2, created.size());
        System.assertEquals('Arvo Seats', created[1].Product__c);
        System.assertEquals(24000, created[1].Annual_Amount__c);

        row.Line_Items__c = OrderFormLines.toJson(OrderFormLines.parse(new List<Object>{
            line('Rogo Seats', 'Platform Fee', 12, null, 60000, 'Annual') }, 12));
        update row;
        System.assertEquals(1, [SELECT COUNT() FROM Order_Form_Line__c WHERE Extraction__c = :row.Id], 'Replaced, not added');

        row.Extraction_Status__c = 'Incomplete';   // a change that leaves the lines alone
        update row;
        System.assertEquals(1, [SELECT COUNT() FROM Order_Form_Line__c WHERE Extraction__c = :row.Id]);

        row.Line_Items__c = null;
        update row;
        System.assertEquals(0, [SELECT COUNT() FROM Order_Form_Line__c WHERE Extraction__c = :row.Id]);
    }

    // Replies with the given lines and keeps the request it was sent.
    private class LinesMock implements HttpCalloutMock {
        List<Object> items;
        String requestBody;
        LinesMock(List<Object> items) { this.items = items; }
        public HttpResponse respond(HttpRequest req) {
            requestBody = req.getBody();
            HttpResponse r = new HttpResponse();
            r.setStatusCode(200);
            r.setHeader('Content-Type', 'application/json');
            r.setBody(JSON.serialize(new Map<String, Object>{
                'id' => 'msg_test', 'type' => 'message', 'role' => 'assistant', 'model' => 'claude-sonnet-5',
                'content' => new List<Object>{ new Map<String, Object>{
                    'type' => 'text', 'text' => JSON.serialize(new Map<String, Object>{ 'Line_Items' => items }) } },
                'stop_reason' => 'end_turn',
                'usage' => new Map<String, Object>{ 'input_tokens' => 100, 'output_tokens' => 50 }
            }));
            return r;
        }
    }

    @isTest
    static void backfillReadsOnlyTheLines() {
        Account a = new Account(Name = 'Lines Backfill Co');
        insert a;
        Opportunity opp = new Opportunity(Name = 'Lines Backfill', StageName = 'Closed Won', CloseDate = Date.today().addDays(-10),
            AccountId = a.Id, Type = 'New Business');
        insert opp;
        Order_Form_Extraction__c row = new Order_Form_Extraction__c(Opportunity__c = opp.Id, Extraction_Status__c = 'Success',
            Is_Current__c = true, Type__c = 'New Business', Annual_Recurring_Revenue__c = 74000, License_Fees__c = 50000,
            Contract_Length_Months__c = 12, Extracted_At__c = System.now().addDays(-5));
        insert row;
        insert new ContentVersion(Title = 'Order Form', PathOnClient = 'Order Form.pdf',
            VersionData = Blob.valueOf('%PDF-1.4 fake bytes for unit test'), FirstPublishLocationId = opp.Id);
        System.assertEquals(1, OrderFormLinesBackfillBatch.countTargets());

        LinesMock mock = new LinesMock(new List<Object>{
            line('Rogo Seats', 'Platform Fee', 10, null, 50000, 'Annual'),
            line('Arvo Seats', 'Arvo Subscription', 20, 100, null, 'Monthly') });
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        Database.executeBatch(new OrderFormLinesBackfillBatch(), 1);
        Test.stopTest();

        Order_Form_Extraction__c after = [SELECT Lines_Read_At__c, Arvo_Seats__c, Lines_Recurring_Annual__c, Lines_Mismatch__c,
                                                 License_Fees__c, Annual_Recurring_Revenue__c
                                          FROM Order_Form_Extraction__c WHERE Id = :row.Id];
        System.assertNotEquals(null, after.Lines_Read_At__c);
        System.assertEquals(20, after.Arvo_Seats__c);
        System.assertEquals(74000, after.Lines_Recurring_Annual__c);
        System.assertEquals(false, after.Lines_Mismatch__c, 'The lines add up to the row\'s ARR');
        System.assertEquals(50000, after.License_Fees__c, 'Nothing else on the row changes');
        System.assertEquals(2, [SELECT COUNT() FROM Order_Form_Line__c WHERE Extraction__c = :row.Id]);
        System.assertEquals(0, OrderFormLinesBackfillBatch.countTargets(), 'Read rows are not read again');

        String systemPrompt = (String) ((Map<String, Object>) JSON.deserializeUntyped(mock.requestBody)).get('system');
        System.assert(systemPrompt.contains('LINE ITEMS:') && systemPrompt.contains('"Line_Items"'), systemPrompt);
        System.assert(!systemPrompt.contains('CREDIT ROLLOVER:'), 'A focused prompt, not the full extraction');
    }
}
