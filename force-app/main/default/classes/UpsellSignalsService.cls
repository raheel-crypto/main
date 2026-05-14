public with sharing class UpsellSignalsService {

    @TestVisible private static String benchmarkCsvOverride;
    @TestVisible private static String bearerTokenOverride;
    @TestVisible private static Boolean skipNarrativeCall = false;
    @TestVisible private static List<Map<String, Object>> gongCallsOverride;

    public class Signal {
        @AuraEnabled public String key;
        @AuraEnabled public String label;
        @AuraEnabled public Integer weight;
        @AuraEnabled public Decimal contributionPoints;
        @AuraEnabled public String detail;
        @AuraEnabled public String status;
    }

    public class UpsellOutput {
        @AuraEnabled public String accountName;
        @AuraEnabled public String accountTier;
        @AuraEnabled public Decimal score;
        @AuraEnabled public List<Signal> signals;
        @AuraEnabled public List<String> warnings;
        @AuraEnabled public String narrativeJobId;
    }

    @AuraEnabled
    public static UpsellOutput compute(
        Id accountId,
        Decimal dauWauObserved,
        Decimal wauEnrolledObserved,
        Decimal qpuObserved
    ) {
        if (accountId == null) {
            throw new AuraHandledException('accountId is required');
        }

        Account a = [
            SELECT Id, Name, ARR__c, Estimated_TAM__c, Total_Licenses__c,
                   Number_of_Bankers__c, Account_Health_Score__c,
                   Business_Type__c, Region__c, Segment__c, Account_Tier__c
            FROM Account
            WHERE Id = :accountId
            LIMIT 1
        ];

        List<Opportunity> opps = [
            SELECT Id, Type, CloseDate, IsWon, Amount
            FROM Opportunity
            WHERE AccountId = :accountId AND IsWon = TRUE
            ORDER BY CloseDate ASC
        ];

        UpsellOutput out = new UpsellOutput();
        out.accountName = a.Name;
        out.accountTier = a.Account_Tier__c;
        out.signals = new List<Signal>();
        out.warnings = new List<String>();

        Map<String, Decimal> benchmark = loadBenchmark(a, out.warnings);

        List<Map<String, Object>> gongCallSummaries = new List<Map<String, Object>>();
        out.signals.add(scoreUsageVsBenchmark(dauWauObserved, wauEnrolledObserved, qpuObserved, benchmark));
        out.signals.add(scoreWhitespace(a));
        out.signals.add(scoreArrTamGap(a));
        out.signals.add(scoreOpportunityCadence(opps));
        out.signals.add(scoreHealth(a));
        out.signals.add(scoreGong(accountId, gongCallSummaries));

        Decimal total = 0;
        for (Signal s : out.signals) {
            if (s.contributionPoints != null) total += s.contributionPoints;
        }
        if (total < 0) total = 0;
        if (total > 100) total = 100;
        out.score = total.setScale(0);

        if (!skipNarrativeCall) {
            try {
                out.narrativeJobId = submitNarrativeJob(a, out,
                    dauWauObserved, wauEnrolledObserved, qpuObserved,
                    gongCallSummaries);
            } catch (Exception e) {
                out.warnings.add('Narrative generation skipped: ' + e.getMessage());
            }
        }
        return out;
    }

    // ------------------------------------------------------------
    // Signal scorers
    // ------------------------------------------------------------

    private static Signal scoreUsageVsBenchmark(
        Decimal dauWauObs, Decimal wauEnrObs, Decimal qpuObs,
        Map<String, Decimal> benchmark
    ) {
        Signal s = new Signal();
        s.key = 'usage_vs_benchmark';
        s.label = 'Usage vs Peer Benchmark';
        s.weight = 25;

        if (dauWauObs == null && wauEnrObs == null && qpuObs == null) {
            s.contributionPoints = 0;
            s.status = 'missing';
            s.detail = 'No observed usage metrics passed in';
            return s;
        }

        Decimal obsDau = dauWauObs != null ? dauWauObs * 100 : null;
        Decimal obsWau = wauEnrObs != null ? wauEnrObs * 100 : null;

        List<String> parts = new List<String>();
        Integer wins = 0;
        wins += compareToBenchmark(obsDau,  benchmark.get('DAU_WAU_PCT'),      parts, 'DAU/WAU');
        wins += compareToBenchmark(obsWau,  benchmark.get('WAU_ENROLLED_PCT'), parts, 'WAU/Enrolled');
        wins += compareToBenchmark(qpuObs,  benchmark.get('QPU'),              parts, 'QPU');

        Decimal normalized = (Decimal.valueOf(wins + 3)) / 6;
        s.contributionPoints = (normalized * s.weight).setScale(1);
        s.detail = String.join(parts, '; ');
        s.status = 'present';
        return s;
    }

    private static Integer compareToBenchmark(Decimal observed, Decimal peer, List<String> parts, String label) {
        if (observed == null || peer == null || peer == 0) {
            parts.add(label + ' n/a');
            return 0;
        }
        Decimal delta = (observed - peer) / peer;
        Integer signum;
        String tag;
        if (delta >= 0.10)        { signum = 1;  tag = 'up'; }
        else if (delta <= -0.10)  { signum = -1; tag = 'down'; }
        else                      { signum = 0;  tag = 'flat'; }
        parts.add(label + ' ' + observed.setScale(1) + ' vs peer ' + peer.setScale(1) + ' ' + tag);
        return signum;
    }

    private static Signal scoreWhitespace(Account a) {
        Signal s = new Signal();
        s.key = 'whitespace';
        s.label = 'Whitespace (uncovered seats)';
        s.weight = 25;
        if (a.Total_Licenses__c == null || a.Number_of_Bankers__c == null || a.Number_of_Bankers__c == 0) {
            s.contributionPoints = 0;
            s.status = 'missing';
            s.detail = 'Total Licenses or # Bankers not populated';
            return s;
        }
        Decimal licensed = a.Total_Licenses__c;
        Decimal bankers = a.Number_of_Bankers__c;
        Decimal uncoveredRatio = (bankers - licensed) / bankers;
        if (uncoveredRatio < 0) uncoveredRatio = 0;
        if (uncoveredRatio > 1) uncoveredRatio = 1;

        s.contributionPoints = (uncoveredRatio * s.weight).setScale(1);
        Decimal uncovered = bankers - licensed;
        if (uncovered < 0) uncovered = 0;
        s.detail = uncovered.intValue() + ' of ' + bankers.intValue()
            + ' bankers uncovered (' + (uncoveredRatio * 100).setScale(0) + '%)';
        s.status = 'present';
        return s;
    }

    private static Signal scoreArrTamGap(Account a) {
        Signal s = new Signal();
        s.key = 'arr_tam_gap';
        s.label = 'ARR vs Estimated TAM';
        s.weight = 20;
        if (a.ARR__c == null || a.Estimated_TAM__c == null || a.Estimated_TAM__c == 0) {
            s.contributionPoints = 0;
            s.status = 'missing';
            s.detail = 'ARR or Estimated TAM not populated';
            return s;
        }
        Decimal penetration = a.ARR__c / a.Estimated_TAM__c;
        if (penetration > 1) penetration = 1;
        if (penetration < 0) penetration = 0;
        Decimal gap = 1 - penetration;
        s.contributionPoints = (gap * s.weight).setScale(1);
        s.detail = '$' + formatThousands(a.ARR__c) + ' of $' + formatThousands(a.Estimated_TAM__c)
            + ' TAM (' + (penetration * 100).setScale(0) + '% captured)';
        s.status = 'present';
        return s;
    }

    private static Signal scoreOpportunityCadence(List<Opportunity> opps) {
        Signal s = new Signal();
        s.key = 'opp_cadence';
        s.label = 'Opportunity Cadence';
        s.weight = 20;

        if (opps == null || opps.isEmpty()) {
            s.contributionPoints = 0;
            s.status = 'missing';
            s.detail = 'No closed-won opportunities found';
            return s;
        }

        Date firstNewBiz;
        Integer upsells = 0, renewals = 0, downsells = 0, pilots = 0;
        Date lastUpsell;

        for (Opportunity o : opps) {
            if (o.Type == 'New Business' && firstNewBiz == null) {
                firstNewBiz = o.CloseDate;
            } else if (o.Type == 'Upsell') {
                upsells++;
                if (lastUpsell == null || o.CloseDate > lastUpsell) lastUpsell = o.CloseDate;
            } else if (o.Type == 'Renewal') {
                renewals++;
            } else if (o.Type == 'Downsell') {
                downsells++;
            } else if (o.Type == 'Pilot') {
                pilots++;
            }
        }

        Decimal pts = 0;
        Integer daysSinceNewBiz;
        if (firstNewBiz != null) {
            daysSinceNewBiz = firstNewBiz.daysBetween(Date.today());
            if (daysSinceNewBiz >= 180 && daysSinceNewBiz <= 540)      pts += 8;
            else if (daysSinceNewBiz > 540)                            pts += 4;
            else                                                       pts += 2;
        }

        if (upsells >= 2) pts += 6;
        else if (upsells == 1) pts += 4;

        if (lastUpsell != null) {
            Integer dsl = lastUpsell.daysBetween(Date.today());
            if (dsl <= 180) pts += 3;
            else if (dsl <= 365) pts += 1;
        }

        if (downsells > 0) pts -= 3;
        if (pilots > 0 && upsells == 0) pts += 2;

        if (pts < 0) pts = 0;
        if (pts > s.weight) pts = s.weight;

        s.contributionPoints = pts.setScale(1);
        s.detail = (daysSinceNewBiz == null ? 'No New Business on file'
                     : 'New Business ' + daysSinceNewBiz + ' days ago')
            + '; ' + upsells + ' upsell' + (upsells == 1 ? '' : 's')
            + ', ' + renewals + ' renewal' + (renewals == 1 ? '' : 's')
            + (downsells > 0 ? ', ' + downsells + ' downsell' + (downsells == 1 ? '' : 's') : '')
            + (pilots > 0 ? ', ' + pilots + ' pilot' + (pilots == 1 ? '' : 's') : '');
        s.status = 'present';
        return s;
    }

    private static Signal scoreHealth(Account a) {
        Signal s = new Signal();
        s.key = 'health';
        s.label = 'Account Health Score';
        s.weight = 10;
        if (a.Account_Health_Score__c == null) {
            s.contributionPoints = 0;
            s.status = 'missing';
            s.detail = 'Account Health Score not populated';
            return s;
        }
        Decimal h = a.Account_Health_Score__c;
        if (h < 0) h = 0;
        if (h > 100) h = 100;
        s.contributionPoints = ((h / 100) * s.weight).setScale(1);
        s.detail = 'Health ' + h.setScale(0) + '/100';
        s.status = 'present';
        return s;
    }

    private static Signal scoreGong(Id accountId, List<Map<String, Object>> outCalls) {
        Signal s = new Signal();
        s.key = 'gong_signals';
        s.label = 'Gong Call Signals (last 7 days)';
        s.weight = 0; // additive modifier on top of the 100

        List<Map<String, Object>> calls;
        if (gongCallsOverride != null) {
            calls = gongCallsOverride;
        } else {
            Schema.SObjectType gongType = Schema.getGlobalDescribe().get('Gong__Gong_Call__c');
            if (gongType == null) {
                s.contributionPoints = 0;
                s.status = 'missing';
                s.detail = 'Gong managed package not installed in this org';
                return s;
            }
            try {
                DateTime since = DateTime.now().addDays(-7);
                List<SObject> rows = Database.query(
                    'SELECT Id, Name, Gong__Call_ID__c, CreatedDate ' +
                    'FROM Gong__Gong_Call__c ' +
                    'WHERE Gong__Primary_Account__c = :accountId ' +
                    'AND CreatedDate >= :since ' +
                    'ORDER BY CreatedDate DESC ' +
                    'LIMIT 25'
                );
                calls = new List<Map<String, Object>>();
                for (SObject r : rows) {
                    calls.add(new Map<String, Object>{
                        'title'       => r.get('Name'),
                        'gongCallId'  => r.get('Gong__Call_ID__c'),
                        'createdDate' => r.get('CreatedDate')
                    });
                }
            } catch (Exception e) {
                s.contributionPoints = 0;
                s.status = 'missing';
                s.detail = 'Gong query failed: ' + e.getMessage();
                return s;
            }
        }

        for (Map<String, Object> c : calls) outCalls.add(c);

        Integer count = calls.size();
        Decimal pts;
        if (count >= 3)      pts = 5;
        else if (count >= 1) pts = 3;
        else                 pts = 0;

        s.contributionPoints = pts;
        s.status = 'present';
        s.detail = count == 0
            ? 'No Gong calls in last 7 days'
            : count + ' call' + (count == 1 ? '' : 's') + ' in last 7 days';
        return s;
    }

    // ------------------------------------------------------------
    // Benchmark lookup
    // ------------------------------------------------------------

    @TestVisible
    private static Map<String, Decimal> loadBenchmark(Account a, List<String> warnings) {
        Map<String, Map<String, Decimal>> rows = parseBenchmarkCsv(loadBenchmarkCsv());
        List<String> preference = new List<String>{
            'Business Type|' + a.Business_Type__c,
            'Segment|' + a.Segment__c,
            'Region|' + a.Region__c,
            'Overall|All Customers'
        };
        for (String k : preference) {
            Map<String, Decimal> row = rows.get(k);
            if (row != null) return row;
        }
        warnings.add('No benchmark row matched any dimension for this account.');
        return new Map<String, Decimal>();
    }

    private static String loadBenchmarkCsv() {
        if (benchmarkCsvOverride != null) return benchmarkCsvOverride;
        List<StaticResource> srs = [SELECT Body FROM StaticResource WHERE Name = 'RogoBenchmarks' LIMIT 1];
        if (srs.isEmpty()) {
            return '';
        }
        return srs[0].Body.toString();
    }

    @TestVisible
    private static Map<String, Map<String, Decimal>> parseBenchmarkCsv(String csv) {
        Map<String, Map<String, Decimal>> result = new Map<String, Map<String, Decimal>>();
        if (String.isBlank(csv)) return result;
        List<String> lines = csv.split('\n');
        for (Integer i = 1; i < lines.size(); i++) {
            String line = lines[i].trim();
            if (String.isBlank(line)) continue;
            List<String> cells = line.split(',');
            if (cells.size() < 6) continue;
            String dim = cells[0].trim();
            String grp = cells[1].trim();
            Map<String, Decimal> row = new Map<String, Decimal>();
            row.put('CUSTOMER_COUNT',   safeDecimal(cells[2]));
            row.put('DAU_WAU_PCT',      safeDecimal(cells[3]));
            row.put('WAU_ENROLLED_PCT', safeDecimal(cells[4]));
            row.put('QPU',              safeDecimal(cells[5]));
            result.put(dim + '|' + grp, row);
        }
        return result;
    }

    // ------------------------------------------------------------
    // Narrative job (Rogo /api/ask)
    // ------------------------------------------------------------

    private static String submitNarrativeJob(
        Account a, UpsellOutput out,
        Decimal dauWau, Decimal wauEnr, Decimal qpu,
        List<Map<String, Object>> gongCallSummaries
    ) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:Rogo_Analytics/api/ask');
        req.setMethod('POST');
        req.setHeader('Authorization', 'Bearer ' + getBearerToken());
        req.setHeader('Content-Type', 'application/json');
        req.setBody(JSON.serialize(new Map<String, Object>{
            'question' => buildNarrativePrompt(a, out, dauWau, wauEnr, qpu, gongCallSummaries),
            'user_name' => UserInfo.getUserName()
        }));
        req.setTimeout(60000);
        HttpResponse res = new Http().send(req);
        Integer code = res.getStatusCode();
        if (code != 200 && code != 202) {
            throw new CalloutException('Rogo narrative submission failed: ' + code + ' ' + res.getBody());
        }
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        return (String) body.get('job_id');
    }

    private static String buildNarrativePrompt(
        Account a, UpsellOutput out,
        Decimal dauWau, Decimal wauEnr, Decimal qpu,
        List<Map<String, Object>> gongCallSummaries
    ) {
        String gongContext = '';
        if (gongCallSummaries != null && !gongCallSummaries.isEmpty()) {
            gongContext = ' Recent Gong calls (last 7 days): ';
            Integer i = 0;
            for (Map<String, Object> c : gongCallSummaries) {
                i++;
                if (i > 5) break;
                String title = (String) c.get('title');
                Datetime cd = (Datetime) c.get('createdDate');
                gongContext += i + ') "' + title + '" on ' + cd.format('yyyy-MM-dd') + '; ';
            }
        }

        return 'You are advising a Customer Success Manager on an upsell opportunity at a customer account. '
            + 'Account: "' + a.Name + '" (Salesforce id ' + a.Id + '). '
            + 'Business Type: ' + nz(a.Business_Type__c) + ', '
            + 'Region: ' + nz(a.Region__c) + ', '
            + 'Segment: ' + nz(a.Segment__c) + ', '
            + 'Tier: ' + nz(a.Account_Tier__c) + '. '
            + 'Computed upsell score: ' + out.score + '/100. '
            + 'Signals (JSON): ' + JSON.serialize(out.signals) + '. '
            + 'Observed last-28-day usage: DAU/WAU=' + pct(dauWau) + ', '
            + 'WAU/Enrolled=' + pct(wauEnr) + ', QPU=' + num(qpu) + '.'
            + gongContext + ' '
            + 'Respond in markdown with EXACTLY two sections. '
            + 'First section header: "## Upsell Opportunity" — 2 to 3 sentences identifying the most likely upsell '
            + '(seat expansion, product line, tier upgrade, or geo expansion) and which signals support it. '
            + 'Reference recent Gong calls by title where they reinforce the recommendation. '
            + 'Second section header: "## Recommended Actions" — a numbered list of 3 specific actions the CSM should take in the next 7 days. '
            + 'Do NOT invent metrics. Reference only the signals above. '
            + 'Do NOT include SQL or data queries — this is synthesis, not a data lookup.';
    }

    // ------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------

    private static String getBearerToken() {
        if (bearerTokenOverride != null) return bearerTokenOverride;
        Rogo_Config__mdt cfg = Rogo_Config__mdt.getInstance('Default');
        if (cfg == null || String.isBlank(cfg.Bearer_Token__c)) {
            throw new AuraHandledException('Rogo bearer token is not configured.');
        }
        return cfg.Bearer_Token__c;
    }

    private static Decimal safeDecimal(String raw) {
        if (String.isBlank(raw)) return null;
        try { return Decimal.valueOf(raw.trim()); } catch (Exception e) { return null; }
    }

    private static String formatThousands(Decimal d) {
        if (d == null) return 'n/a';
        String raw = String.valueOf(d.longValue());
        Boolean neg = raw.startsWith('-');
        if (neg) raw = raw.substring(1);
        Integer len = raw.length();
        if (len <= 3) return (neg ? '-' : '') + raw;
        String result = raw.substring(len - 3, len);
        Integer i = len - 3;
        while (i > 3) {
            result = raw.substring(i - 3, i) + ',' + result;
            i -= 3;
        }
        result = raw.substring(0, i) + ',' + result;
        return (neg ? '-' : '') + result;
    }

    private static String nz(String v) { return String.isBlank(v) ? 'n/a' : v; }
    private static String pct(Decimal v) { return v == null ? 'n/a' : (v * 100).setScale(1) + '%'; }
    private static String num(Decimal v) { return v == null ? 'n/a' : v.setScale(1).toPlainString(); }
}
