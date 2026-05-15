public with sharing class UpsellSignalsService {

    @TestVisible private static Integer LOOKBACK_DAYS = 14;

    @TestVisible private static String benchmarkCsvOverride;
    @TestVisible private static String bearerTokenOverride;
    @TestVisible private static Boolean skipNarrativeCall = false;
    @TestVisible private static List<Map<String, Object>> gongCallsOverride;
    @TestVisible private static List<Map<String, Object>> activitiesOverride;

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

    public class SavedInsight {
        @AuraEnabled public String payloadJson;
        @AuraEnabled public Decimal score;
        @AuraEnabled public DateTime lastRunAt;
        @AuraEnabled public String lastRunByName;
    }

    @AuraEnabled(cacheable=true)
    public static SavedInsight getLastInsight(Id accountId) {
        if (accountId == null) return null;
        List<Upsell_Insight__c> rows = [
            SELECT Score__c, Payload_Json__c, LastModifiedDate, LastModifiedBy.Name
            FROM Upsell_Insight__c
            WHERE Account__c = :accountId
            ORDER BY LastModifiedDate DESC
            LIMIT 1
        ];
        if (rows.isEmpty()) return null;
        return toSavedInsight(rows[0]);
    }

    @AuraEnabled
    public static SavedInsight saveInsight(Id accountId, String payloadJson, Decimal score) {
        if (accountId == null) {
            throw new AuraHandledException('accountId is required');
        }
        if (String.isBlank(payloadJson)) {
            throw new AuraHandledException('payloadJson is required');
        }
        List<Upsell_Insight__c> existing = [
            SELECT Id FROM Upsell_Insight__c WHERE Account__c = :accountId LIMIT 1
        ];
        Upsell_Insight__c rec = existing.isEmpty()
            ? new Upsell_Insight__c(Account__c = accountId)
            : existing[0];
        rec.Score__c = score;
        rec.Payload_Json__c = payloadJson;
        upsert rec;

        Upsell_Insight__c saved = [
            SELECT Score__c, Payload_Json__c, LastModifiedDate, LastModifiedBy.Name
            FROM Upsell_Insight__c WHERE Id = :rec.Id LIMIT 1
        ];
        return toSavedInsight(saved);
    }

    private static SavedInsight toSavedInsight(Upsell_Insight__c r) {
        SavedInsight si = new SavedInsight();
        si.payloadJson = r.Payload_Json__c;
        si.score = r.Score__c;
        si.lastRunAt = r.LastModifiedDate;
        si.lastRunByName = r.LastModifiedBy != null ? r.LastModifiedBy.Name : null;
        return si;
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
        List<Map<String, Object>> activitySummaries = new List<Map<String, Object>>();
        out.signals.add(scoreUsageVsBenchmark(dauWauObserved, wauEnrolledObserved, qpuObserved, benchmark));
        out.signals.add(scoreWhitespace(a));
        out.signals.add(scoreArrTamGap(a));
        out.signals.add(scoreOpportunityCadence(opps));
        out.signals.add(scoreHealth(a));
        out.signals.add(scoreGong(accountId, gongCallSummaries));
        out.signals.add(scoreTasksAndEvents(accountId, activitySummaries));

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
                    gongCallSummaries, activitySummaries);
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
        s.weight = 30;

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
        s.weight = 10;
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
        s.label = 'Opportunity History';
        s.weight = 20;

        if (opps == null || opps.isEmpty()) {
            s.contributionPoints = 0;
            s.status = 'missing';
            s.detail = 'No closed-won opportunities found';
            return s;
        }

        Date firstNewBiz;
        List<Opportunity> renewalsList = new List<Opportunity>();
        Integer upsells = 0, renewals = 0, typeDownsells = 0, pilots = 0;
        Date lastUpsell;

        for (Opportunity o : opps) {
            if (o.Type == 'New Business' && firstNewBiz == null) {
                firstNewBiz = o.CloseDate;
            } else if (o.Type == 'Upsell') {
                upsells++;
                if (lastUpsell == null || o.CloseDate > lastUpsell) lastUpsell = o.CloseDate;
            } else if (o.Type == 'Renewal') {
                renewals++;
                renewalsList.add(o);
            } else if (o.Type == 'Downsell') {
                typeDownsells++;
            } else if (o.Type == 'Pilot') {
                pilots++;
            }
        }

        Integer amountDeclines = 0;
        Decimal priorRenewalAmount;
        for (Opportunity r : renewalsList) {
            if (priorRenewalAmount != null && r.Amount != null && r.Amount < priorRenewalAmount) {
                amountDeclines++;
            }
            if (r.Amount != null) priorRenewalAmount = r.Amount;
        }

        Integer tenureDays;
        if (firstNewBiz != null) tenureDays = firstNewBiz.daysBetween(Date.today());

        Decimal pts = 0;
        if (renewals >= 2) pts += 6;
        else if (renewals == 1) pts += 4;
        else if (tenureDays != null && tenureDays < 365) pts += 2;

        if (upsells >= 2)      pts += 5;
        else if (upsells == 1) pts += 3;

        if (lastUpsell != null) {
            Integer dsl = lastUpsell.daysBetween(Date.today());
            if (dsl <= 180) pts += 2;
            else if (dsl <= 365) pts += 1;
        }

        if (renewals >= 2 && upsells <= 1) pts += 4;
        if (pilots > 0 && upsells == 0) pts += 2;
        if (typeDownsells > 0) pts -= 3;
        if (amountDeclines > 0) pts -= 3;

        if (pts < 0) pts = 0;
        if (pts > s.weight) pts = s.weight;

        s.contributionPoints = pts.setScale(1);
        s.detail = buildOppHistoryDetail(opps, tenureDays, renewals, upsells, typeDownsells, amountDeclines);
        s.status = 'present';
        return s;
    }

    private static String buildOppHistoryDetail(
        List<Opportunity> opps,
        Integer tenureDays,
        Integer renewals,
        Integer upsells,
        Integer typeDownsells,
        Integer amountDeclines
    ) {
        List<String> headerParts = new List<String>();
        if (tenureDays != null) headerParts.add('Customer ' + tenureDays + 'd');
        if (renewals > 0) headerParts.add(renewals + ' renewal' + (renewals == 1 ? '' : 's'));
        if (upsells > 0) headerParts.add(upsells + ' upsell' + (upsells == 1 ? '' : 's'));
        if (typeDownsells > 0) headerParts.add(typeDownsells + ' downsell' + (typeDownsells == 1 ? '' : 's'));
        if (amountDeclines > 0) headerParts.add('renewal amount declined');

        List<String> sequence = new List<String>();
        for (Opportunity o : opps) {
            String label;
            if      (o.Type == 'New Business') label = 'NB';
            else if (o.Type == 'Upsell')       label = 'Upsell';
            else if (o.Type == 'Renewal')      label = 'Renewal';
            else if (o.Type == 'Downsell')     label = 'Downsell';
            else if (o.Type == 'Pilot')        label = 'Pilot';
            else                                label = (o.Type == null ? '?' : o.Type);
            String amt = o.Amount == null ? '?' : '$' + formatThousands(o.Amount);
            sequence.add(label + ' ' + amt);
        }

        String headline = headerParts.isEmpty() ? 'No history' : String.join(headerParts, ' · ');
        String history = sequence.isEmpty() ? '' : ' — ' + String.join(sequence, ' → ');
        return headline + history;
    }

    private static Signal scoreHealth(Account a) {
        Signal s = new Signal();
        s.key = 'health';
        s.label = 'Account Health Score';
        s.weight = 15;
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

    private static final Set<String> UPSELL_TERMS = new Set<String>{
        'expansion', 'expand', 'upsell', 'upgrade', 'more seats',
        'additional users', 'additional licenses', 'additional license',
        'new product', 'add-on', 'addon', 'tier ii', 'tier iii',
        'enterprise', 'growth', 'scale up', 'scaling', 'roll out',
        'rollout', 'pilot to', 'expand to', 'team expansion'
    };
    private static final Set<String> CONCERN_TERMS = new Set<String>{
        'cancel', 'cancellation', 'churn', 'frustrated', 'unhappy',
        'pricing pushback', 'pricing concern', 'price concern',
        'budget cut', 'budget freeze', 'reduce seats', 'downsize',
        'competitor', 'switching', 'leaving', 'evaluating alternatives'
    };

    private static Signal scoreGong(Id accountId, List<Map<String, Object>> outCalls) {
        Signal s = new Signal();
        s.key = 'gong_signals';
        s.label = 'Gong Call Signals (last ' + LOOKBACK_DAYS + ' days)';
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
                DateTime since = DateTime.now().addDays(-LOOKBACK_DAYS);
                List<SObject> rows = Database.query(
                    'SELECT Id, Name, Gong__Title__c, Gong__Call_ID__c, ' +
                    'Gong__Call_Start__c, Gong__Call_Duration_sec__c, ' +
                    'Gong__Direction__c, Gong__Talk_Time_Us__c, Gong__Talk_Time_Them__c, ' +
                    'Gong__Call_Score__c, Gong__Call_Outcome__c, Gong__Call_Result__c, ' +
                    'Gong__Call_Brief__c, Gong__Call_Key_Points__c, ' +
                    'Gong__Call_Highlights_Next_Steps__c, ' +
                    'Gong__Related_Topics_json__c, Gong__Related_Trackers_json__c, ' +
                    'Gong__Primary_User__c, CreatedDate ' +
                    'FROM Gong__Gong_Call__c ' +
                    'WHERE Gong__Primary_Account__c = :accountId ' +
                    'AND Gong__Call_Start__c >= :since ' +
                    'ORDER BY Gong__Call_Start__c DESC ' +
                    'LIMIT 25'
                );
                calls = new List<Map<String, Object>>();
                for (SObject r : rows) {
                    calls.add(new Map<String, Object>{
                        'title'       => firstNonBlank((String) r.get('Gong__Title__c'), (String) r.get('Name')),
                        'gongCallId'  => r.get('Gong__Call_ID__c'),
                        'callStart'   => r.get('Gong__Call_Start__c'),
                        'createdDate' => r.get('CreatedDate'),
                        'durationSec' => r.get('Gong__Call_Duration_sec__c'),
                        'direction'   => r.get('Gong__Direction__c'),
                        'talkUs'      => r.get('Gong__Talk_Time_Us__c'),
                        'talkThem'    => r.get('Gong__Talk_Time_Them__c'),
                        'callScore'   => r.get('Gong__Call_Score__c'),
                        'outcome'     => r.get('Gong__Call_Outcome__c'),
                        'result'      => r.get('Gong__Call_Result__c'),
                        'brief'       => r.get('Gong__Call_Brief__c'),
                        'keyPoints'   => r.get('Gong__Call_Key_Points__c'),
                        'nextSteps'   => r.get('Gong__Call_Highlights_Next_Steps__c'),
                        'topicsJson'  => r.get('Gong__Related_Topics_json__c'),
                        'trackersJson'=> r.get('Gong__Related_Trackers_json__c'),
                        'primaryUser' => r.get('Gong__Primary_User__c')
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

        Integer upsellHits = 0;
        Integer concernHits = 0;
        for (Map<String, Object> c : calls) {
            String haystack = (
                nullToBlank((String) c.get('brief')) + ' ' +
                nullToBlank((String) c.get('keyPoints')) + ' ' +
                nullToBlank((String) c.get('nextSteps')) + ' ' +
                nullToBlank((String) c.get('outcome')) + ' ' +
                nullToBlank((String) c.get('result')) + ' ' +
                nullToBlank((String) c.get('trackersJson')) + ' ' +
                nullToBlank((String) c.get('topicsJson'))
            ).toLowerCase();
            for (String t : UPSELL_TERMS)  if (haystack.contains(t)) { upsellHits++; break; }
            for (String t : CONCERN_TERMS) if (haystack.contains(t)) { concernHits++; break; }
        }
        pts += upsellHits;
        pts -= concernHits;
        if (pts > 5) pts = 5;
        if (pts < -5) pts = -5;

        List<String> detailParts = new List<String>();
        if (count > 0) detailParts.add(count + ' call' + (count == 1 ? '' : 's'));
        else           detailParts.add('No calls in last ' + LOOKBACK_DAYS + ' days');
        if (upsellHits > 0)  detailParts.add(upsellHits + ' with upsell talk');
        if (concernHits > 0) detailParts.add(concernHits + ' with concern talk');

        s.contributionPoints = pts;
        s.status = 'present';
        s.detail = String.join(detailParts, ' · ');
        return s;
    }

    private static String firstNonBlank(String a, String b) {
        return String.isNotBlank(a) ? a : (String.isNotBlank(b) ? b : null);
    }
    private static String nullToBlank(String s) { return s == null ? '' : s; }

    // ------------------------------------------------------------
    // Tasks & Events signal
    // ------------------------------------------------------------

    private static Signal scoreTasksAndEvents(Id accountId, List<Map<String, Object>> outActivities) {
        Signal s = new Signal();
        s.key = 'tasks_events';
        s.label = 'Tasks & Events (last ' + LOOKBACK_DAYS + ' days)';
        s.weight = 0; // additive modifier on top of the 100

        List<Map<String, Object>> activities;
        if (activitiesOverride != null) {
            activities = activitiesOverride;
        } else {
            activities = new List<Map<String, Object>>();
            try {
                DateTime sinceDt = DateTime.now().addDays(-LOOKBACK_DAYS);
                Date sinceDate = Date.today().addDays(-LOOKBACK_DAYS);
                for (Task t : [
                    SELECT Id, Subject, Description, CreatedDate, Type, Status
                    FROM Task
                    WHERE (AccountId = :accountId OR WhatId = :accountId)
                      AND CreatedDate >= :sinceDt
                    ORDER BY CreatedDate DESC
                    LIMIT 50
                ]) {
                    activities.add(new Map<String, Object>{
                        'kind'        => 'Task',
                        'subject'     => t.Subject,
                        'description' => t.Description,
                        'when'        => t.CreatedDate,
                        'type'        => t.Type,
                        'status'      => t.Status
                    });
                }
                for (Event e : [
                    SELECT Id, Subject, Description, ActivityDate, StartDateTime, Type
                    FROM Event
                    WHERE (AccountId = :accountId OR WhatId = :accountId)
                      AND ActivityDate >= :sinceDate
                    ORDER BY ActivityDate DESC
                    LIMIT 50
                ]) {
                    activities.add(new Map<String, Object>{
                        'kind'        => 'Event',
                        'subject'     => e.Subject,
                        'description' => e.Description,
                        'when'        => e.StartDateTime != null ? (Object) e.StartDateTime : (Object) e.ActivityDate,
                        'type'        => e.Type
                    });
                }
            } catch (Exception ex) {
                s.contributionPoints = 0;
                s.status = 'missing';
                s.detail = 'Task/Event query failed: ' + ex.getMessage();
                return s;
            }
        }

        for (Map<String, Object> a : activities) outActivities.add(a);

        Integer taskCount = 0;
        Integer eventCount = 0;
        Integer upsellHits = 0;
        Integer concernHits = 0;
        for (Map<String, Object> a : activities) {
            String kind = (String) a.get('kind');
            if (kind == 'Task') taskCount++;
            else if (kind == 'Event') eventCount++;

            String haystack = (
                nullToBlank((String) a.get('subject')) + ' ' +
                nullToBlank((String) a.get('description'))
            ).toLowerCase();
            for (String t : UPSELL_TERMS)  if (haystack.contains(t)) { upsellHits++; break; }
            for (String t : CONCERN_TERMS) if (haystack.contains(t)) { concernHits++; break; }
        }

        Integer total = taskCount + eventCount;
        Decimal pts;
        if (total >= 4)      pts = 4;
        else if (total >= 1) pts = 2;
        else                 pts = 0;
        pts += upsellHits;
        pts -= concernHits;
        if (pts > 5) pts = 5;
        if (pts < -5) pts = -5;

        List<String> detailParts = new List<String>();
        if (taskCount > 0)  detailParts.add(taskCount + ' email/task' + (taskCount == 1 ? '' : 's'));
        if (eventCount > 0) detailParts.add(eventCount + ' event' + (eventCount == 1 ? '' : 's'));
        if (detailParts.isEmpty()) detailParts.add('No activity in last ' + LOOKBACK_DAYS + ' days');
        if (upsellHits > 0)  detailParts.add(upsellHits + ' with upsell talk');
        if (concernHits > 0) detailParts.add(concernHits + ' with concern talk');

        s.contributionPoints = pts;
        s.status = 'present';
        s.detail = String.join(detailParts, ' · ');
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
        List<Map<String, Object>> gongCallSummaries,
        List<Map<String, Object>> activitySummaries
    ) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:Rogo_Analytics/api/ask');
        req.setMethod('POST');
        req.setHeader('Authorization', 'Bearer ' + getBearerToken());
        req.setHeader('Content-Type', 'application/json');
        req.setBody(JSON.serialize(new Map<String, Object>{
            'question' => buildNarrativePrompt(a, out, dauWau, wauEnr, qpu, gongCallSummaries, activitySummaries),
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
        List<Map<String, Object>> gongCallSummaries,
        List<Map<String, Object>> activitySummaries
    ) {
        String gongContext = '';
        if (gongCallSummaries != null && !gongCallSummaries.isEmpty()) {
            gongContext = '\n\nRecent Gong calls (last ' + LOOKBACK_DAYS + ' days, most recent first):\n';
            Integer i = 0;
            for (Map<String, Object> c : gongCallSummaries) {
                i++;
                if (i > 5) break;
                String title = (String) c.get('title');
                Datetime callDt = (Datetime) c.get('callStart');
                if (callDt == null) callDt = (Datetime) c.get('createdDate');
                String dateStr = callDt != null ? callDt.format('yyyy-MM-dd') : 'unknown date';

                gongContext += i + ') "' + title + '" (' + dateStr + ')';
                Decimal durSec = (Decimal) c.get('durationSec');
                if (durSec != null) gongContext += ', ' + (durSec / 60).setScale(0) + ' min';
                gongContext += '.';

                String brief = truncate((String) c.get('brief'), 400);
                if (String.isNotBlank(brief)) gongContext += ' BRIEF: ' + brief;

                String kp = truncate((String) c.get('keyPoints'), 400);
                if (String.isNotBlank(kp)) gongContext += ' KEY POINTS: ' + kp;

                String ns = truncate((String) c.get('nextSteps'), 300);
                if (String.isNotBlank(ns)) gongContext += ' NEXT STEPS: ' + ns;

                String trackers = extractTrackerNames((String) c.get('trackersJson'));
                if (String.isNotBlank(trackers)) gongContext += ' TRACKERS: ' + trackers + '.';

                gongContext += '\n';
            }
        }

        String activityContext = '';
        if (activitySummaries != null && !activitySummaries.isEmpty()) {
            activityContext = '\n\nRecent emails / tasks / events (last ' + LOOKBACK_DAYS + ' days, most recent first):\n';
            Integer i = 0;
            for (Map<String, Object> ax : activitySummaries) {
                i++;
                if (i > 8) break;
                String kind = (String) ax.get('kind');
                String subject = (String) ax.get('subject');
                Object whenObj = ax.get('when');
                String dateStr = 'unknown date';
                if (whenObj instanceof Datetime) dateStr = ((Datetime) whenObj).format('yyyy-MM-dd');
                else if (whenObj instanceof Date) dateStr = String.valueOf(whenObj);
                activityContext += i + ') ' + kind + ': "' + nz(subject) + '" (' + dateStr + ').';
                String typeVal = (String) ax.get('type');
                if (String.isNotBlank(typeVal)) activityContext += ' TYPE: ' + typeVal + '.';
                String descText = truncate((String) ax.get('description'), 400);
                if (String.isNotBlank(descText)) activityContext += ' DESC: ' + descText;
                activityContext += '\n';
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
            + gongContext
            + activityContext + '\n\n'
            + 'Important framing rules: '
            + '(1) Tenure (e.g. "Customer 751d") is stickiness, NOT a sales gap — do not describe long tenure as "time since New Business" or "751-day gap". '
            + '(2) Renewals are annual; "2 renewals" means a 2-year+ customer who has stayed twice. '
            + '(3) If the opportunity-history detail says "renewal amount declined", treat that as a recoverable downsell already in the data — call it out as a specific risk to recover via expansion, not as churn alarm. '
            + '(4) An account with several renewals but few upsells is UNDER-MONETIZED — that is the clearest expansion signal, even when ARR/TAM headroom is moderate. '
            + '(5) Read the score in context: scores in the 45-65 range with strong usage and health are still high-priority pursuits, not "lukewarm". '
            + '\n\n'
            + 'Respond in markdown with EXACTLY two sections. '
            + 'First section header: "## Upsell Opportunity" — 2 to 3 sentences identifying the most likely upsell '
            + '(seat expansion, product line, tier upgrade, or geo expansion) and which signals support it. '
            + 'Quote specific phrases or trackers from the Gong calls, recent emails, or events where they reinforce the recommendation, '
            + 'or surface contrary signals (concerns, churn risk, renewal amount declines) if present. '
            + 'Second section header: "## Recommended Actions" — a numbered list of 3 specific actions the CSM should take in the next 7 days. '
            + 'Tie each action to either a Gong call (reference by title), a usage gap, a specific whitespace number, or the opportunity history. '
            + 'Do NOT invent metrics. Reference only the signals above. '
            + 'Do NOT include SQL or data queries — this is synthesis, not a data lookup.';
    }

    private static String truncate(String s, Integer maxLen) {
        if (s == null) return null;
        s = s.replaceAll('\\s+', ' ').trim();
        return s.length() > maxLen ? s.substring(0, maxLen) + '…' : s;
    }

    private static String extractTrackerNames(String trackersJson) {
        if (String.isBlank(trackersJson)) return null;
        try {
            Object parsed = JSON.deserializeUntyped(trackersJson);
            if (!(parsed instanceof List<Object>)) return null;
            List<String> names = new List<String>();
            for (Object item : (List<Object>) parsed) {
                if (item instanceof Map<String, Object>) {
                    Map<String, Object> m = (Map<String, Object>) item;
                    Object n = m.get('name');
                    if (n == null) n = m.get('Name');
                    if (n != null) {
                        Object count = m.get('count');
                        names.add(count == null ? String.valueOf(n) : String.valueOf(n) + ' (x' + count + ')');
                    }
                }
                if (names.size() >= 10) break;
            }
            return names.isEmpty() ? null : String.join(names, ', ');
        } catch (Exception e) {
            return null;
        }
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
