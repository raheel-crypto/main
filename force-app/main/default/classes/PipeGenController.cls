public with sharing class PipeGenController {

    // ─── Wrapper Classes ────────────────────────────────────────────────────────

    public class DashboardData {
        @AuraEnabled public QuarterlyTarget        quarterlyTarget;
        @AuraEnabled public List<AccountRow>       targetAccounts;
        @AuraEnabled public List<OppRow>           inFlightOpps;
        @AuraEnabled public List<Weekly_Commit__c> thisWeekCommits;
        @AuraEnabled public ScorecardData          lastWeekScorecard;
    }

    public class QuarterlyTarget {
        @AuraEnabled public Decimal        pipelineTarget;
        @AuraEnabled public Decimal        pipelineActual;
        @AuraEnabled public Integer        weeksRemaining;
        @AuraEnabled public String         quarter;
        @AuraEnabled public List<StageCard> stageCards;
    }

    public class StageCard {
        @AuraEnabled public String  stageName;
        @AuraEnabled public Integer oppCount;
        @AuraEnabled public Decimal amount;
        @AuraEnabled public Boolean isClosedWon;
    }

    public class AccountRow {
        @AuraEnabled public String   id;
        @AuraEnabled public String   name;
        @AuraEnabled public String   type;
        @AuraEnabled public Date     lastActivityDate;
        @AuraEnabled public String   lastActivitySubject;
        @AuraEnabled public DateTime lastGongCallDate;
        @AuraEnabled public Integer  contactCount;
    }

    public class OppRow {
        @AuraEnabled public String   id;
        @AuraEnabled public String   name;
        @AuraEnabled public String   stageName;
        @AuraEnabled public Decimal  amount;
        @AuraEnabled public String   accountName;
        @AuraEnabled public String   accountId;
        @AuraEnabled public Integer  daysInStage;
        @AuraEnabled public Integer  staleThreshold;
        @AuraEnabled public Date     lastActivityDate;
        @AuraEnabled public DateTime lastGongCallDate;
        @AuraEnabled public Integer  contactRoleCount;
        @AuraEnabled public Boolean  isStale;
        @AuraEnabled public Date     closeDate;
    }

    public class ScorecardData {
        @AuraEnabled public Integer nnCommitsTotal;
        @AuraEnabled public Integer nnCommitsCompleted;
        @AuraEnabled public Decimal nnDollarGenerated;
        @AuraEnabled public Integer nnOppsCreated;
        @AuraEnabled public Integer progCommitsTotal;
        @AuraEnabled public Integer progCommitsCompleted;
        @AuraEnabled public Integer progOppsAdvanced;
        @AuraEnabled public Integer progOppsStalled;
        @AuraEnabled public Decimal progConversionRate;
    }

    public class AccountCard {
        @AuraEnabled public String  id;
        @AuraEnabled public String  name;
        @AuraEnabled public String  type;
        @AuraEnabled public String  industry;
        @AuraEnabled public Boolean isTargeted;
        @AuraEnabled public Integer contactCount;
        @AuraEnabled public Integer openOppCount;
        @AuraEnabled public String  accountStatus;
        @AuraEnabled public Decimal arr;
        @AuraEnabled public String  accountTier;
        @AuraEnabled public Decimal estimatedTam;
        @AuraEnabled public Integer bankerCount;
        @AuraEnabled public String  website;
        @AuraEnabled public String  segment;
        @AuraEnabled public Date    lastActivityDate;
        @AuraEnabled public Integer earlyStageOppCount;
    }

    public class ManagerDashboardData {
        @AuraEnabled public List<RepSummary> reps;
        @AuraEnabled public TeamSummary      teamSummary;
    }

    public class TeamSummary {
        @AuraEnabled public Integer totalReps;
        @AuraEnabled public Integer totalCommits;
        @AuraEnabled public Integer completedCommits;
        @AuraEnabled public Integer atRiskCommitCount;
        @AuraEnabled public Integer repsWithNoCommits;
    }

    public class RepSummary {
        @AuraEnabled public String                 repId;
        @AuraEnabled public String                 repName;
        @AuraEnabled public List<Weekly_Commit__c> thisWeekCommits;
        @AuraEnabled public ScorecardData          lastWeekScorecard;
        @AuraEnabled public List<String>           riskReasons;
        @AuraEnabled public Boolean                hasRisk;
        @AuraEnabled public Integer                inFlightOppCount;
        @AuraEnabled public Integer                thisWeekTotal;
        @AuraEnabled public Integer                thisWeekCompleted;
    }

    // ─── Config ─────────────────────────────────────────────────────────────────

    private static final String STAGE_DEMO        = '1 - Demo';
    private static final String STAGE_DISCOVERY   = '2 - Discovery';
    private static final String STAGE_POV         = '3 - POV';
    private static final String STAGE_PROPOSAL    = '4 - Proposal';
    private static final String STAGE_CONTRACTING = '5 - Contracting';
    private static final String STAGE_CLOSED_WON  = 'Closed Won';
    private static final String STAGE_CLOSED_LOST = 'Closed Lost';

    // All open in-flight stages
    private static final Set<String> IN_FLIGHT_STAGES = new Set<String>{
        STAGE_DEMO, STAGE_DISCOVERY, STAGE_POV, STAGE_PROPOSAL, STAGE_CONTRACTING
    };

    // Pipeline target = 2-Discovery and beyond (excludes 1-Demo)
    private static final Set<String> PIPELINE_STAGES = new Set<String>{
        STAGE_DISCOVERY, STAGE_POV, STAGE_PROPOSAL, STAGE_CONTRACTING, STAGE_CLOSED_WON
    };

    // Stage order for display
    private static final List<String> STAGE_ORDER = new List<String>{
        STAGE_DEMO, STAGE_DISCOVERY, STAGE_POV, STAGE_PROPOSAL, STAGE_CONTRACTING, STAGE_CLOSED_WON
    };

    // Stages where a progression commit counts as "advanced"
    private static final Set<String> ADVANCED_STAGES = new Set<String>{
        STAGE_POV, STAGE_PROPOSAL, STAGE_CONTRACTING, STAGE_CLOSED_WON
    };

    private static final Map<String, Integer> STALE_THRESHOLDS = new Map<String, Integer>{
        STAGE_DEMO        => 21,
        STAGE_DISCOVERY   => 14,
        STAGE_POV         => 14,
        STAGE_PROPOSAL    => 10,
        STAGE_CONTRACTING => 7
    };

    // ─── Nektar Activity Verification ────────────────────────────────────────────

    // Maps Commit_Type__c → Meeting_Type__c values on Event that verify it.
    // null value = any meeting type qualifies (used for Multi-Thread).
    private static final Map<String, Set<String>> COMMIT_MEETING_MAP = new Map<String, Set<String>>{
        'First Meeting Booked'            => new Set<String>{ 'First Meeting' },
        'Multi-Thread Intro'              => new Set<String>{ 'First Meeting', 'Discovery', 'Prospect Meeting' },
        'Champion-Led Referral'           => new Set<String>{ 'First Meeting' },
        'Inbound Converted'               => new Set<String>{ 'Discovery', 'Prospect Meeting' },
        'Discovery Call - Economic Buyer' => new Set<String>{ 'Discovery' },
        'Technical Validation'            => new Set<String>{ 'POV Validation & Alignment', 'POV Readout' },
        'Exec Alignment'                  => new Set<String>{ 'Deal Progression' },
        'Multi-Thread'                    => null
    };

    private static final String COMMIT_EXEC_OUTREACH = 'Exec Outreach Sequence';
    private static final String COMMIT_MEDDPICC      = 'MEDDPICC Complete';

    // Nektar DM persona title keywords — longest/most specific phrases first
    // so a contains() check on "Managing Director" fires before the broader "Director"
    private static final List<String> DM_TITLE_KEYWORDS = new List<String>{
        'Managing Director Investment Banking', 'Director Investment Banking',
        'Senior Managing Director', 'Executive Director', 'Investment Director',
        'Managing Director', 'General Partner', 'Portfolio Manager',
        'Head of M&A', 'Head of Investments', 'Director of Research',
        'Head of Equity Research', 'Head of Credit', 'Head of Private Equity',
        'Head of Macro', 'Head of Quantitative Research', 'Head of Fixed Income',
        'Head of Trading', 'Head of Capital Markets',
        'Partner', 'Principal', 'Director', 'MD'
    };

    // ─── Main Entry Point ────────────────────────────────────────────────────────

    @AuraEnabled(cacheable=false)
    public static DashboardData getRepDashboardData() {
        Id userId = UserInfo.getUserId();
        DashboardData d = new DashboardData();
        d.quarterlyTarget   = buildQuarterlyTarget(userId);
        d.targetAccounts    = buildTargetAccounts(userId);
        d.inFlightOpps      = buildInFlightOpps(userId);
        d.thisWeekCommits   = buildThisWeekCommits(userId);
        d.lastWeekScorecard = buildLastWeekScorecard(userId);
        return d;
    }

    // ─── Quarterly Target ────────────────────────────────────────────────────────

    private static QuarterlyTarget buildQuarterlyTarget(Id userId) {
        QuarterlyTarget qt = new QuarterlyTarget();
        Date today = Date.today();

        Integer qStartMonth = ((today.month() - 1) / 3) * 3 + 1;
        Date qStart = Date.newInstance(today.year(), qStartMonth, 1);
        Date qEnd   = qStart.addMonths(3).addDays(-1);
        qt.quarter        = 'Q' + ((qStartMonth / 3) + 1) + ' ' + today.year();
        qt.weeksRemaining = Math.max(0, today.daysBetween(qEnd) / 7);

        Decimal annual = 0;
        try {
            User u = [SELECT Pipe_Gen_Annual_Target__c FROM User WHERE Id = :userId LIMIT 1];
            annual = u.Pipe_Gen_Annual_Target__c != null ? u.Pipe_Gen_Annual_Target__c : 0;
        } catch (Exception e) { annual = 0; }
        qt.pipelineTarget = annual / 4;

        // Opps created this quarter
        Set<Id> createdThisQtr = new Set<Id>();
        for (Opportunity o : [
            SELECT Id FROM Opportunity
            WHERE OwnerId = :userId
              AND CreatedDate >= :qStart
              AND CreatedDate <= :qEnd
              AND StageName != :STAGE_CLOSED_LOST
        ]) { createdThisQtr.add(o.Id); }

        // Opps progressed into pipeline stages (2+) this quarter
        // NewValue is not filterable in SOQL, so filter in Apex
        Set<Id> progressedThisQtr = new Set<Id>();
        for (OpportunityFieldHistory h : [
            SELECT OpportunityId, NewValue
            FROM OpportunityFieldHistory
            WHERE Field      = 'StageName'
              AND CreatedDate >= :qStart
              AND CreatedDate <= :qEnd
        ]) {
            if (PIPELINE_STAGES.contains((String)h.NewValue))
                progressedThisQtr.add(h.OpportunityId);
        }

        Set<Id> qualifyingIds = new Set<Id>(createdThisQtr);
        qualifyingIds.addAll(progressedThisQtr);

        // Initialize stage cards
        Map<String, StageCard> cardMap = new Map<String, StageCard>();
        for (String s : STAGE_ORDER) {
            StageCard sc  = new StageCard();
            sc.stageName  = s;
            sc.oppCount   = 0;
            sc.amount     = 0;
            sc.isClosedWon = (s == STAGE_CLOSED_WON);
            cardMap.put(s, sc);
        }

        Decimal pipelineActual = 0;
        if (!qualifyingIds.isEmpty()) {
            for (Opportunity o : [
                SELECT Id, StageName, Amount, ARR__c
                FROM Opportunity
                WHERE Id IN :qualifyingIds
                  AND OwnerId = :userId
                  AND StageName != :STAGE_CLOSED_LOST
            ]) {
                StageCard sc = cardMap.get(o.StageName);
                if (sc == null) continue;
                sc.oppCount++;
                Decimal val = (o.StageName == STAGE_CLOSED_WON)
                    ? (o.ARR__c != null ? o.ARR__c : 0)
                    : (o.Amount  != null ? o.Amount  : 0);
                sc.amount += val;
                if (PIPELINE_STAGES.contains(o.StageName)) pipelineActual += val;
            }
        }

        qt.pipelineActual = pipelineActual;
        qt.stageCards     = new List<StageCard>();
        for (String s : STAGE_ORDER) qt.stageCards.add(cardMap.get(s));
        return qt;
    }

    // ─── Target Accounts ────────────────────────────────────────────────────────

    private static List<AccountRow> buildTargetAccounts(Id userId) {
        List<AccountRow> rows = new List<AccountRow>();

        List<Account> accounts = [
            SELECT Id, Name, Type,
                (SELECT Name, Gong__Call_Start__c
                 FROM Gong__Conversations__r
                 ORDER BY Gong__Call_Start__c DESC LIMIT 1),
                (SELECT Id FROM Contacts WHERE IsDeleted = false)
            FROM Account
            WHERE OwnerId = :userId
              AND Target_Account__c = true
            ORDER BY Name ASC
            LIMIT 150
        ];

        for (Account a : accounts) {
            AccountRow row   = new AccountRow();
            row.id           = a.Id;
            row.name         = a.Name;
            row.type         = a.Type;
            row.contactCount = a.Contacts.size();
            // We'll populate lastActivityDate separately to avoid ActivityHistories relationship restriction
            if (!a.Gong__Conversations__r.isEmpty()) {
                row.lastGongCallDate = a.Gong__Conversations__r[0].Gong__Call_Start__c;
            }
            rows.add(row);
        }
        
        // Populate lastActivityDate using an Event aggregate per Account to avoid ActivityHistories
        Set<Id> acctIds = new Set<Id>();
        for (AccountRow r : rows) acctIds.add(r.id);
        if (!acctIds.isEmpty()) {
            for (AggregateResult ar : [
                SELECT AccountId acctId, MAX(StartDateTime) maxDateTime
                FROM Event
                WHERE AccountId IN :acctIds
                  AND StartDateTime != null
                GROUP BY AccountId
            ]) {
                Id aid = (Id) ar.get('acctId');
                Datetime maxDt = (Datetime) ar.get('maxDateTime');
                Date maxDate = maxDt != null ? maxDt.date() : null;
                for (AccountRow r : rows) {
                    if (r.id == aid) {
                        r.lastActivityDate = maxDate;
                        break;
                    }
                }
            }
            // Populate lastActivitySubject if needed: do a lightweight query for latest Event subject per account
            for (Event e : [
                SELECT AccountId, Subject, ActivityDate
                FROM Event
                WHERE AccountId IN :acctIds
                  AND ActivityDate != null
                ORDER BY AccountId ASC, ActivityDate DESC
            ]) {
                for (AccountRow r : rows) {
                    if (r.id == e.AccountId && r.lastActivitySubject == null) {
                        r.lastActivitySubject = e.Subject;
                        break;
                    }
                }
            }
        }
        return rows;
    }

    // ─── In-Flight Opps (Stage 1 + Stage 2) ─────────────────────────────────────

    private static List<OppRow> buildInFlightOpps(Id userId) {
        List<OppRow> rows = new List<OppRow>();

        List<Opportunity> opps = [
            SELECT Id, Name, StageName, Amount, CloseDate, AccountId, Account.Name,
                (SELECT Name, Gong__Call_Start__c
                 FROM Gong__Conversations__r
                 ORDER BY Gong__Call_Start__c DESC LIMIT 1),
                (SELECT Id FROM OpportunityContactRoles WHERE IsDeleted = false)
            FROM Opportunity
            WHERE OwnerId = :userId
              AND StageName IN :IN_FLIGHT_STAGES
              AND IsClosed = false
            ORDER BY StageName ASC, CreatedDate ASC
        ];

        if (opps.isEmpty()) return rows;

        // Find when each opp last entered its CURRENT stage
        Set<Id> oppIds = new Map<Id, Opportunity>(opps).keySet();
        Map<Id, DateTime> stageEntry = new Map<Id, DateTime>();
        for (OpportunityFieldHistory h : [
            SELECT OpportunityId, NewValue, CreatedDate
            FROM OpportunityFieldHistory
            WHERE Field = 'StageName'
              AND OpportunityId IN :oppIds
            ORDER BY CreatedDate DESC
        ]) {
            // Match history entry to the opp's current stage — first hit (most recent) wins
            Opportunity o = opps[0]; // placeholder; we look up below
            if (!stageEntry.containsKey(h.OpportunityId)) {
                stageEntry.put(h.OpportunityId, null); // reserve slot
            }
        }

        // Build a lookup map for opp current stage, then re-scan history
        Map<Id, String> oppCurrentStage = new Map<Id, String>();
        for (Opportunity o : opps) oppCurrentStage.put(o.Id, o.StageName);

        stageEntry.clear();
        for (OpportunityFieldHistory h : [
            SELECT OpportunityId, NewValue, CreatedDate
            FROM OpportunityFieldHistory
            WHERE Field = 'StageName'
              AND OpportunityId IN :oppIds
            ORDER BY CreatedDate DESC
        ]) {
            String currentStage = oppCurrentStage.get(h.OpportunityId);
            if (h.NewValue == currentStage && !stageEntry.containsKey(h.OpportunityId)) {
                stageEntry.put(h.OpportunityId, h.CreatedDate);
            }
        }

        Date today = Date.today();
        for (Opportunity o : opps) {
            OppRow row           = new OppRow();
            row.id               = o.Id;
            row.name             = o.Name;
            row.stageName        = o.StageName;
            row.amount           = o.Amount;
            row.accountName      = o.Account.Name;
            row.accountId        = o.AccountId;
            row.closeDate        = o.CloseDate;
            row.contactRoleCount = o.OpportunityContactRoles.size();
            row.staleThreshold   = STALE_THRESHOLDS.containsKey(o.StageName)
                                    ? STALE_THRESHOLDS.get(o.StageName) : 21;

            DateTime entry  = stageEntry.get(o.Id);
            row.daysInStage = entry != null ? entry.date().daysBetween(today) : 0;
            row.isStale     = row.daysInStage > row.staleThreshold;

            // Fetch recent activity dates via Event query to avoid ActivityHistories relationship restriction
            row.lastActivityDate = null;
            row.lastGongCallDate = null;
            rows.add(row);
        }
        
        // Populate lastActivityDate and lastGongCallDate for the opp rows with a single Event query
        Set<Id> oppIdsWithRows = new Set<Id>();
        for (OppRow r : rows) oppIdsWithRows.add(r.id);
        if (!oppIdsWithRows.isEmpty()) {
            // Recent Events (ActivityDate) per Opportunity
            for (AggregateResult ar : [
                SELECT WhatId oppId, MAX(StartDateTime) maxDateTime
                FROM Event
                WHERE WhatId IN :oppIdsWithRows
                  AND StartDateTime != null
                GROUP BY WhatId
            ]) {
                Id oppId = (Id) ar.get('oppId');
                Datetime maxDt = (Datetime) ar.get('maxDateTime');
                Date maxDate = maxDt != null ? maxDt.date() : null;
                for (OppRow r : rows) {
                    if (r.id == oppId) {
                        r.lastActivityDate = maxDate;
                        break;
                    }
                }
            }
            // Gong call timestamps per Opportunity (via relationship field on Conversation)
            for (AggregateResult ar2 : [
                SELECT Gong__Primary_Opportunity__c oppId, MAX(Gong__Call_Start__c) maxGong
                FROM Gong__Gong_Call__c
                WHERE Gong__Primary_Opportunity__c IN :oppIds
                GROUP BY Gong__Primary_Opportunity__c
            ]) {
                Id oppId = (Id) ar2.get('oppId');
                Datetime maxGong = (Datetime) ar2.get('maxGong');
                for (OppRow r : rows) {
                    if (r.id == oppId) {
                        r.lastGongCallDate = maxGong;
                        break;
                    }
                }
            }
        }
        return rows;
    }

    // ─── This Week's Commits ─────────────────────────────────────────────────────

    private static List<Weekly_Commit__c> buildThisWeekCommits(Id userId) {
        Date weekStart = getWeekStart(Date.today());
        Date weekEnd   = weekStart.addDays(6);
        List<Weekly_Commit__c> commits = [
            SELECT Id, Motion_Type__c, Commit_Type__c, Commit_Description__c,
                   Target_Account__c, Target_Account__r.Name,
                   Target_Opportunity__c, Target_Opportunity__r.Name,
                   Committed_Count__c, Actual_Count__c,
                   Completion_Status__c, Gong_Verified__c, Notes__c
            FROM Weekly_Commit__c
            WHERE Rep__c = :userId
              AND Week_Start_Date__c = :weekStart
            ORDER BY Motion_Type__c ASC, CreatedDate ASC
        ];
        return verifyAndPersistCommits(commits, userId, weekStart, weekEnd);
    }

    // ─── Last Week's Scorecard ───────────────────────────────────────────────────

    private static ScorecardData buildLastWeekScorecard(Id userId) {
        ScorecardData sc = new ScorecardData();
        Date lastWeekStart = getWeekStart(Date.today()).addDays(-7);
        Date lastWeekEnd   = lastWeekStart.addDays(6);

        // Verify last week's commits against actual activity before scoring
        List<Weekly_Commit__c> lastWeekCommits = [
            SELECT Id, Motion_Type__c, Commit_Type__c, Completion_Status__c,
                   Committed_Count__c, Actual_Count__c,
                   Target_Account__c, Target_Opportunity__c
            FROM Weekly_Commit__c
            WHERE Rep__c = :userId
              AND Week_Start_Date__c = :lastWeekStart
        ];
        lastWeekCommits = verifyAndPersistCommits(lastWeekCommits, userId, lastWeekStart, lastWeekEnd);

        sc.nnCommitsTotal       = 0;
        sc.nnCommitsCompleted   = 0;
        sc.progCommitsTotal     = 0;
        sc.progCommitsCompleted = 0;
        sc.progOppsAdvanced     = 0;
        sc.progOppsStalled      = 0;

        // Query opportunity stages separately to avoid relationship issues
        Set<Id> progOppIds = new Set<Id>();
        for (Weekly_Commit__c c : lastWeekCommits) {
            if (c.Motion_Type__c == 'Progression' && c.Target_Opportunity__c != null) {
                progOppIds.add(c.Target_Opportunity__c);
            }
        }
        
        Map<Id, String> oppStages = new Map<Id, String>();
        if (!progOppIds.isEmpty()) {
            for (Opportunity o : [SELECT Id, StageName FROM Opportunity WHERE Id IN :progOppIds]) {
                oppStages.put(o.Id, o.StageName);
            }
        }

        for (Weekly_Commit__c c : lastWeekCommits) {
            if (c.Motion_Type__c == 'Net New') {
                sc.nnCommitsTotal++;
                if (c.Completion_Status__c == 'Completed') sc.nnCommitsCompleted++;
            } else if (c.Motion_Type__c == 'Progression') {
                sc.progCommitsTotal++;
                if (c.Completion_Status__c == 'Completed') sc.progCommitsCompleted++;
                if (c.Target_Opportunity__c != null && oppStages.containsKey(c.Target_Opportunity__c)) {
                    String stage = oppStages.get(c.Target_Opportunity__c);
                    if (ADVANCED_STAGES.contains(stage)) sc.progOppsAdvanced++;
                    else sc.progOppsStalled++;
                }
            }
        }

        AggregateResult[] nnRes = [
            SELECT SUM(Amount) tot, COUNT(Id) cnt
            FROM Opportunity
            WHERE OwnerId = :userId
              AND CreatedDate >= :lastWeekStart
              AND CreatedDate <= :lastWeekEnd
        ];
        sc.nnDollarGenerated = nnRes[0].get('tot') != null ? (Decimal)nnRes[0].get('tot') : 0;
        sc.nnOppsCreated     = nnRes[0].get('cnt') != null ? (Integer)nnRes[0].get('cnt') : 0;

        sc.progConversionRate = sc.progCommitsTotal > 0
            ? (sc.progOppsAdvanced * 100.0 / sc.progCommitsTotal)
            : 0;

        return sc;
    }

    // ─── Commit Mutations ────────────────────────────────────────────────────────

    @AuraEnabled
    public static Weekly_Commit__c saveCommit(Weekly_Commit__c commitRecord) {
        commitRecord.Rep__c             = UserInfo.getUserId();
        commitRecord.Week_Start_Date__c = getWeekStart(Date.today());
        upsert commitRecord;
        return [
            SELECT Id, Rep__c, Week_Start_Date__c, Motion_Type__c, Commit_Type__c, Commit_Description__c,
                   Target_Account__c, Target_Account__r.Name,
                   Target_Opportunity__c, Target_Opportunity__r.Name,
                   Committed_Count__c, Actual_Count__c,
                   Completion_Status__c, Gong_Verified__c, Notes__c
            FROM Weekly_Commit__c WHERE Id = :commitRecord.Id
        ];
    }

    @AuraEnabled
    public static void deleteCommit(Id commitId) {
        delete new Weekly_Commit__c(Id = commitId);
    }

    // Sets Actual_Count__c to the committed amount and marks complete — MEDDPICC manual override
    @AuraEnabled
    public static void markCommitComplete(Id commitId) {
        Weekly_Commit__c c = [
            SELECT Id, Committed_Count__c
            FROM Weekly_Commit__c
            WHERE Id = :commitId
            LIMIT 1
        ];
        c.Actual_Count__c      = c.Committed_Count__c != null ? c.Committed_Count__c.intValue() : 1;
        c.Completion_Status__c = 'Completed';
        update c;
    }

    // ─── Activity Verification ───────────────────────────────────────────────────

    // Matches each commit to Nektar-enriched Events (and Tasks for Exec Outreach),
    // updates Actual_Count__c and Completion_Status__c, persists changes, returns commits.
    private static List<Weekly_Commit__c> verifyAndPersistCommits(
            List<Weekly_Commit__c> commits, Id userId, Date weekStart, Date weekEnd) {

        if (commits.isEmpty()) return commits;

        Set<Id> targetAcctIds = new Set<Id>();
        Set<Id> targetOppIds  = new Set<Id>();
        Set<Id> execAcctIds   = new Set<Id>();

        for (Weekly_Commit__c c : commits) {
            if (c.Commit_Type__c == COMMIT_MEDDPICC) continue;
            if (c.Target_Account__c    != null) targetAcctIds.add(c.Target_Account__c);
            if (c.Target_Opportunity__c != null) targetOppIds.add(c.Target_Opportunity__c);
            if (c.Commit_Type__c == COMMIT_EXEC_OUTREACH && c.Target_Account__c != null)
                execAcctIds.add(c.Target_Account__c);
        }

        // Events: Net New commits match on AccountId; Progression commits match on WhatId (= Opp)
        Map<Id, List<String>> meetingsByAcct = new Map<Id, List<String>>();
        Map<Id, List<String>> meetingsByOpp  = new Map<Id, List<String>>();

        if (!targetAcctIds.isEmpty() || !targetOppIds.isEmpty()) {
            for (Event e : [
                SELECT Meeting_Type__c, AccountId, WhatId
                FROM Event
                WHERE OwnerId = :userId
                  AND ActivityDate >= :weekStart
                  AND ActivityDate <= :weekEnd
                  AND Meeting_Type__c != null
                  AND (AccountId IN :targetAcctIds OR WhatId IN :targetOppIds)
            ]) {
                if (e.AccountId != null && targetAcctIds.contains(e.AccountId)) {
                    if (!meetingsByAcct.containsKey(e.AccountId))
                        meetingsByAcct.put(e.AccountId, new List<String>());
                    meetingsByAcct.get(e.AccountId).add(e.Meeting_Type__c);
                }
                if (e.WhatId != null && targetOppIds.contains(e.WhatId)) {
                    if (!meetingsByOpp.containsKey(e.WhatId))
                        meetingsByOpp.put(e.WhatId, new List<String>());
                    meetingsByOpp.get(e.WhatId).add(e.Meeting_Type__c);
                }
            }
        }

        // Tasks: Exec Outreach — contact Title must match DM persona list
        Map<Id, Integer> execHitsByAcct = new Map<Id, Integer>();
        if (!execAcctIds.isEmpty()) {
            List<Task> tasks = [
                SELECT WhoId, AccountId
                FROM Task
                WHERE OwnerId = :userId
                  AND ActivityDate >= :weekStart
                  AND ActivityDate <= :weekEnd
                  AND AccountId IN :execAcctIds
                  AND WhoId != null
            ];
            Set<Id> contactIds = new Set<Id>();
            for (Task t : tasks) {
                if (String.valueOf(t.WhoId).startsWith('003')) contactIds.add(t.WhoId);
            }
            Map<Id, String> titleByContact = new Map<Id, String>();
            for (Contact c : [
                SELECT Id, Title FROM Contact WHERE Id IN :contactIds AND Title != null
            ]) { titleByContact.put(c.Id, c.Title); }

            for (Task t : tasks) {
                if (!isDmTitle(titleByContact.get(t.WhoId))) continue;
                Integer prev = execHitsByAcct.get(t.AccountId);
                execHitsByAcct.put(t.AccountId, prev != null ? prev + 1 : 1);
            }
        }

        // Compute new actuals and derive status; only DML records that actually changed
        List<Weekly_Commit__c> toUpdate = new List<Weekly_Commit__c>();

        for (Weekly_Commit__c c : commits) {
            Integer newActual;
            String  newStatus;

            if (c.Commit_Type__c == COMMIT_MEDDPICC) {
                newActual = c.Actual_Count__c != null ? c.Actual_Count__c.intValue() : 0;
                newStatus = deriveStatus(newActual, c.Committed_Count__c);
                if (newStatus == c.Completion_Status__c) continue;
                c.Completion_Status__c = newStatus;
                toUpdate.add(new Weekly_Commit__c(Id = c.Id, Completion_Status__c = newStatus));
                continue;
            }

            if (c.Commit_Type__c == COMMIT_EXEC_OUTREACH && c.Target_Account__c != null) {
                Integer h = execHitsByAcct.get(c.Target_Account__c);
                newActual = h != null ? h : 0;

            } else if (c.Motion_Type__c == 'Net New' && c.Target_Account__c != null) {
                Set<String> mapped   = COMMIT_MEETING_MAP.get(c.Commit_Type__c);
                List<String> meetings = meetingsByAcct.get(c.Target_Account__c);
                newActual = 0;
                if (meetings != null && mapped != null)
                    for (String mt : meetings) if (mapped.contains(mt)) newActual++;

            } else if (c.Motion_Type__c == 'Progression' && c.Target_Opportunity__c != null) {
                Set<String> mapped    = COMMIT_MEETING_MAP.get(c.Commit_Type__c);
                List<String> meetings = meetingsByOpp.get(c.Target_Opportunity__c);
                newActual = 0;
                if (meetings != null)
                    for (String mt : meetings)
                        if (mapped == null || mapped.contains(mt)) newActual++;

            } else {
                continue; // no target linked — nothing to verify
            }

            newStatus = deriveStatus(newActual, c.Committed_Count__c);
            Integer oldActual = c.Actual_Count__c != null ? c.Actual_Count__c.intValue() : -1;
            if (newActual == oldActual && newStatus == c.Completion_Status__c) continue;

            // Never auto-downgrade from Completed — preserves manually-set or prior completions
            if ('Completed'.equals(c.Completion_Status__c) && !'Completed'.equals(newStatus)) continue;

            c.Actual_Count__c      = newActual;
            c.Completion_Status__c = newStatus;
            toUpdate.add(new Weekly_Commit__c(
                Id = c.Id, Actual_Count__c = newActual, Completion_Status__c = newStatus
            ));
        }

        if (!toUpdate.isEmpty()) update toUpdate;
        return commits;
    }

    private static String deriveStatus(Integer actual, Decimal committed) {
        Integer target = committed != null ? committed.intValue() : 1;
        if (actual >= target) return 'Completed';
        if (actual > 0)       return 'Partial';
        return 'Not Started';
    }

    private static Boolean isDmTitle(String title) {
        if (String.isBlank(title)) return false;
        String tl = title.toLowerCase();
        for (String kw : DM_TITLE_KEYWORDS) {
            if (tl.contains(kw.toLowerCase())) return true;
        }
        return false;
    }

    // ─── Account Selection ───────────────────────────────────────────────────────

    @AuraEnabled(cacheable=false)
    public static List<AccountCard> getAccountsForSelection() {
        Id   userId       = UserInfo.getUserId();
        Date today        = Date.today();
        Date thirtyAgo    = today.addDays(-30);
        Date sixMonthsAgo = today.addDays(-180);

        List<Account> accounts = [
            SELECT Id, Name, Type, Industry, Target_Account__c, Website,
                   Account_Status__c, ARR__c, Account_Tier__c,
                   Estimated_TAM__c, Number_of_Bankers__c,
                   (SELECT Id, StageName, Type, CloseDate, IsClosed
                    FROM Opportunities WHERE IsDeleted = false
                    ORDER BY CloseDate DESC LIMIT 50),
                   (SELECT Id FROM Contacts WHERE IsDeleted = false)
            FROM Account
            WHERE OwnerId = :userId
            ORDER BY Name ASC
            LIMIT 300
        ];

        Set<Id> acctIds = new Map<Id, Account>(accounts).keySet();
        Map<Id, Date> lastActivityByAcct = new Map<Id, Date>();
        for (AggregateResult ar : [
            SELECT AccountId aid, MAX(StartDateTime) maxDt
            FROM Event
            WHERE AccountId IN :acctIds
              AND StartDateTime != null
            GROUP BY AccountId
        ]) {
            Datetime dt = (Datetime) ar.get('maxDt');
            lastActivityByAcct.put((Id)ar.get('aid'), dt != null ? dt.date() : null);
        }

        List<AccountCard> cards = new List<AccountCard>();
        for (Account a : accounts) {
            Integer openOppCount   = 0;
            Integer earlyStageCount = 0;
            Boolean hasRecentCL    = false;
            Boolean hasOldCL       = false;
            Boolean hasOnlyOldCL   = true;

            for (Opportunity o : a.Opportunities) {
                if (!o.IsClosed) {
                    openOppCount++;
                    hasOnlyOldCL = false;
                    if (o.StageName == STAGE_DEMO || o.StageName == STAGE_DISCOVERY)
                        earlyStageCount++;
                } else if (o.StageName == STAGE_CLOSED_LOST && o.CloseDate != null) {
                    if (o.CloseDate >= sixMonthsAgo) hasRecentCL = true;
                    else hasOldCL = true;
                }
            }

            AccountCard card       = new AccountCard();
            card.id                = a.Id;
            card.name              = a.Name;
            card.type              = a.Type;
            card.industry          = a.Industry;
            card.isTargeted        = a.Target_Account__c;
            card.contactCount      = a.Contacts.size();
            card.openOppCount      = openOppCount;
            card.earlyStageOppCount = earlyStageCount;
            card.accountStatus     = a.Account_Status__c;
            card.arr               = a.ARR__c;
            card.accountTier       = a.Account_Tier__c;
            card.estimatedTam      = a.Estimated_TAM__c;
            card.bankerCount       = a.Number_of_Bankers__c != null ? a.Number_of_Bankers__c.intValue() : 0;
            card.website           = a.Website;
            card.lastActivityDate  = lastActivityByAcct.get(a.Id);
            card.segment           = computeSegment(
                a.Account_Status__c, a.ARR__c, openOppCount, earlyStageCount,
                hasRecentCL, hasOldCL, hasOnlyOldCL,
                lastActivityByAcct.get(a.Id), thirtyAgo
            );
            cards.add(card);
        }
        return cards;
    }

    private static String computeSegment(
        String status, Decimal arr, Integer openCount, Integer earlyCount,
        Boolean hasRecentCL, Boolean hasOldCL, Boolean hasOnlyOldCL,
        Date lastActivity, Date thirtyAgo
    ) {
        Boolean isCustomer       = 'Customer'.equals(status);
        Boolean isFormerCustomer = 'Former Customer'.equals(status);
        Boolean isProspect       = 'Prospect'.equals(status);

        if (isCustomer && arr != null && arr > 0) return 'Expansion';
        if (earlyCount > 0 && !isCustomer && !isFormerCustomer) return 'Early Stage';
        if (isProspect && (openCount == 0 || hasOnlyOldCL)) return 'Uncracked';
        if (!isCustomer && !isFormerCustomer && openCount == 0 && hasRecentCL) return 'Recent Closed Lost';
        if (!isCustomer && !isFormerCustomer && openCount == 0
                && lastActivity != null && lastActivity >= thirtyAgo) return 'No Opportunities';
        return 'Other';
    }

    @AuraEnabled
    public static void updateTargetAccounts(List<Id> toTarget, List<Id> toUntarget) {
        List<Account> updates = new List<Account>();
        for (Id id : (toTarget   != null ? toTarget   : new List<Id>())) updates.add(new Account(Id = id, Target_Account__c = true));
        for (Id id : (toUntarget != null ? toUntarget : new List<Id>())) updates.add(new Account(Id = id, Target_Account__c = false));
        if (!updates.isEmpty()) update updates;
    }

    // ─── Manager Dashboard ───────────────────────────────────────────────────────

    @AuraEnabled(cacheable=false)
    public static ManagerDashboardData getManagerTeamData() {
        Id   mgr       = UserInfo.getUserId();
        Date weekStart = getWeekStart(Date.today());
        Date lwStart   = weekStart.addDays(-7);

        List<User> reps = [
            SELECT Id, Name
            FROM   User
            WHERE  ManagerId = :mgr
              AND  IsActive   = true
            ORDER BY Name
        ];
        ManagerDashboardData result = new ManagerDashboardData();
        result.reps        = new List<RepSummary>();
        result.teamSummary = new TeamSummary();
        result.teamSummary.totalReps         = reps.size();
        result.teamSummary.totalCommits      = 0;
        result.teamSummary.completedCommits  = 0;
        result.teamSummary.atRiskCommitCount = 0;
        result.teamSummary.repsWithNoCommits = 0;
        if (reps.isEmpty()) return result;

        Set<Id> repIds = new Map<Id, User>(reps).keySet();

        // ── This week commits (one query for whole team) ─────────────────────
        Map<Id, List<Weekly_Commit__c>> twByRep = new Map<Id, List<Weekly_Commit__c>>();
        for (Id rid : repIds) twByRep.put(rid, new List<Weekly_Commit__c>());
        for (Weekly_Commit__c c : [
            SELECT Id, Rep__c, Motion_Type__c, Commit_Type__c, Commit_Description__c,
                   Target_Account__c, Target_Account__r.Name,
                   Target_Opportunity__c, Target_Opportunity__r.Name,
                   Committed_Count__c, Actual_Count__c,
                   Completion_Status__c, Manager_Note__c, At_Risk__c, Notes__c
            FROM   Weekly_Commit__c
            WHERE  Rep__c IN :repIds
              AND  Week_Start_Date__c = :weekStart
            ORDER BY Motion_Type__c ASC, CreatedDate ASC
        ]) { twByRep.get(c.Rep__c).add(c); }

        // ── Last week commits (scorecard) ────────────────────────────────────
        Map<Id, List<Weekly_Commit__c>> lwByRep = new Map<Id, List<Weekly_Commit__c>>();
        for (Id rid : repIds) lwByRep.put(rid, new List<Weekly_Commit__c>());
        for (Weekly_Commit__c c : [
            SELECT Id, Rep__c, Motion_Type__c, Completion_Status__c,
                   Committed_Count__c, Target_Opportunity__c
            FROM   Weekly_Commit__c
            WHERE  Rep__c IN :repIds
              AND  Week_Start_Date__c = :lwStart
        ]) { lwByRep.get(c.Rep__c).add(c); }

        // ── In-flight opp count per rep (risk signal) ────────────────────────
        Map<Id, Integer> inFlightByRep = new Map<Id, Integer>();
        for (Id rid : repIds) inFlightByRep.put(rid, 0);
        for (AggregateResult ar : [
            SELECT OwnerId rid, COUNT(Id) cnt
            FROM   Opportunity
            WHERE  OwnerId IN :repIds
              AND  StageName IN :IN_FLIGHT_STAGES
              AND  IsClosed   = false
            GROUP BY OwnerId
        ]) { inFlightByRep.put((Id)ar.get('rid'), (Integer)ar.get('cnt')); }

        // ── Opp stages for last-week scorecard ───────────────────────────────
        Set<Id> allOppIds = new Set<Id>();
        for (List<Weekly_Commit__c> lst : lwByRep.values())
            for (Weekly_Commit__c c : lst)
                if (c.Target_Opportunity__c != null) allOppIds.add(c.Target_Opportunity__c);

        Map<Id, String> oppStages = new Map<Id, String>();
        if (!allOppIds.isEmpty())
            for (Opportunity o : [SELECT Id, StageName FROM Opportunity WHERE Id IN :allOppIds])
                oppStages.put(o.Id, o.StageName);

        // ── Build per-rep summaries ───────────────────────────────────────────
        Integer teamTotal = 0, teamCompleted = 0, teamAtRisk = 0, teamNoCommits = 0;

        for (User rep : reps) {
            List<Weekly_Commit__c> twCommits = twByRep.get(rep.Id);
            List<Weekly_Commit__c> lwCommits = lwByRep.get(rep.Id);
            Integer inFlight = inFlightByRep.get(rep.Id);

            RepSummary rs        = new RepSummary();
            rs.repId             = rep.Id;
            rs.repName           = rep.Name;
            rs.thisWeekCommits   = twCommits;
            rs.inFlightOppCount  = inFlight;
            rs.lastWeekScorecard = buildRepScorecard(lwCommits, oppStages);
            rs.riskReasons       = computeRiskReasons(twCommits, inFlight);
            rs.hasRisk           = !rs.riskReasons.isEmpty();
            rs.thisWeekTotal     = twCommits.size();
            rs.thisWeekCompleted = 0;
            for (Weekly_Commit__c c : twCommits) {
                if (c.Completion_Status__c == 'Completed') rs.thisWeekCompleted++;
                if (c.At_Risk__c) teamAtRisk++;
            }
            teamTotal     += twCommits.size();
            teamCompleted += rs.thisWeekCompleted;
            if (twCommits.isEmpty()) teamNoCommits++;

            result.reps.add(rs);
        }

        result.teamSummary.totalReps         = reps.size();
        result.teamSummary.totalCommits      = teamTotal;
        result.teamSummary.completedCommits  = teamCompleted;
        result.teamSummary.atRiskCommitCount = teamAtRisk;
        result.teamSummary.repsWithNoCommits = teamNoCommits;
        return result;
    }

    @AuraEnabled
    public static List<Weekly_Commit__c> carryForwardIncompleteCommits() {
        Id   userId        = UserInfo.getUserId();
        Date weekStart     = getWeekStart(Date.today());
        Date lastWeekStart = weekStart.addDays(-7);

        List<Weekly_Commit__c> incomplete = [
            SELECT Motion_Type__c, Commit_Type__c, Commit_Description__c,
                   Target_Account__c, Target_Opportunity__c, Committed_Count__c, Notes__c
            FROM Weekly_Commit__c
            WHERE Rep__c = :userId
              AND Week_Start_Date__c = :lastWeekStart
              AND Completion_Status__c != 'Completed'
        ];
        if (incomplete.isEmpty()) return new List<Weekly_Commit__c>();

        List<Weekly_Commit__c> toInsert = new List<Weekly_Commit__c>();
        for (Weekly_Commit__c c : incomplete) {
            toInsert.add(new Weekly_Commit__c(
                Rep__c                = userId,
                Week_Start_Date__c    = weekStart,
                Motion_Type__c        = c.Motion_Type__c,
                Commit_Type__c        = c.Commit_Type__c,
                Commit_Description__c = c.Commit_Description__c,
                Target_Account__c     = c.Target_Account__c,
                Target_Opportunity__c = c.Target_Opportunity__c,
                Committed_Count__c    = c.Committed_Count__c,
                Notes__c              = c.Notes__c
            ));
        }
        insert toInsert;

        return [
            SELECT Id, Motion_Type__c, Commit_Type__c, Commit_Description__c,
                   Target_Account__c, Target_Account__r.Name,
                   Target_Opportunity__c, Target_Opportunity__r.Name,
                   Committed_Count__c, Actual_Count__c,
                   Completion_Status__c, Gong_Verified__c, Notes__c
            FROM Weekly_Commit__c
            WHERE Id IN :toInsert
            ORDER BY Motion_Type__c ASC, CreatedDate ASC
        ];
    }

    @AuraEnabled
    public static void saveManagerNote(Id commitId, String note) {
        update new Weekly_Commit__c(Id = commitId, Manager_Note__c = note);
    }

    @AuraEnabled
    public static void setAtRiskFlag(Id commitId, Boolean atRisk) {
        update new Weekly_Commit__c(Id = commitId, At_Risk__c = atRisk);
    }

    private static List<String> computeRiskReasons(List<Weekly_Commit__c> commits, Integer inFlightCount) {
        List<String> reasons = new List<String>();
        if (commits.isEmpty()) {
            reasons.add('No commits this week');
            return reasons;
        }
        Integer progCount = 0, completedCount = 0;
        for (Weekly_Commit__c c : commits) {
            if (c.Motion_Type__c == 'Progression') progCount++;
            if (c.Completion_Status__c == 'Completed') completedCount++;
        }
        if (progCount == 0 && inFlightCount > 0)
            reasons.add(inFlightCount + ' in-flight opp' + (inFlightCount > 1 ? 's' : '') + ', no progression commit');
        if (completedCount == 0)
            reasons.add(commits.size() + ' commit' + (commits.size() > 1 ? 's' : '') + ' logged, none completed');
        return reasons;
    }

    private static ScorecardData buildRepScorecard(List<Weekly_Commit__c> commits, Map<Id, String> oppStages) {
        ScorecardData sc    = new ScorecardData();
        sc.nnCommitsTotal   = 0; sc.nnCommitsCompleted  = 0;
        sc.progCommitsTotal = 0; sc.progCommitsCompleted = 0;
        sc.progOppsAdvanced = 0; sc.progOppsStalled = 0;
        sc.nnDollarGenerated = 0; sc.nnOppsCreated = 0;
        for (Weekly_Commit__c c : commits) {
            if (c.Motion_Type__c == 'Net New') {
                sc.nnCommitsTotal++;
                if (c.Completion_Status__c == 'Completed') sc.nnCommitsCompleted++;
            } else if (c.Motion_Type__c == 'Progression') {
                sc.progCommitsTotal++;
                if (c.Completion_Status__c == 'Completed') sc.progCommitsCompleted++;
                String stage = oppStages.get(c.Target_Opportunity__c);
                if (ADVANCED_STAGES.contains(stage))  sc.progOppsAdvanced++;
                else if (stage != null)                sc.progOppsStalled++;
            }
        }
        sc.progConversionRate = sc.progCommitsTotal > 0
            ? (sc.progOppsAdvanced * 100.0 / sc.progCommitsTotal) : 0;
        return sc;
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────────

    // Returns the Monday of the week containing d
    @TestVisible
    private static Date getWeekStart(Date d) {
        // Jan 1, 1900 was a Monday - use it as reference
        Date monday1900 = Date.newInstance(1900, 1, 1);
        Integer daysSince = monday1900.daysBetween(d);
        Integer dow = Math.mod(daysSince, 7);
        return d.addDays(-dow);
    }
}
