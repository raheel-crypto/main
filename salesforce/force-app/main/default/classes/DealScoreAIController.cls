public with sharing class DealScoreAIController {

    // ─── Named Credential for Claude API ──────────────────────────
    // Set up an External Credential + Named Credential called 'Anthropic_Claude'
    // with the base URL: https://api.anthropic.com
    // Add a header: x-api-key → your Anthropic API key
    // Add a header: anthropic-version → 2023-06-01
    private static final String NAMED_CREDENTIAL = 'callout:Anthropic_Claude';
    private static final String MODEL = 'claude-sonnet-4-6';

    // Callout timeout for the Claude request. The screen flow keeps the 30 second
    // default so a slow model does not hang the screen; background callers such as
    // CloseAiAnalysisJob raise it (Apex allows up to 120000 ms) before calling in.
    public static Integer calloutTimeoutMs = 30000;

    @AuraEnabled(cacheable=false)
    public static DealAnalysis getAIAnalysis(Id opportunityId, Decimal scorePercent, String tierAction) {
        try {
            // 1. Gather all context (+ resolved mode: WON / LOST / ACTIVE)
            DealContext dc = buildContext(opportunityId, scorePercent, tierAction);

            // 2. Call Claude
            String aiResponse = callClaude(dc.text, dc.mode);

            // 3. Parse response
            DealAnalysis result = parseResponse(aiResponse);

            return result;
        } catch (Exception e) {
            DealAnalysis fallback = new DealAnalysis();
            fallback.summary = 'Unable to generate AI analysis: ' + e.getMessage();
            fallback.recommendations = new List<String>();
            fallback.activityInsights = '';
            return fallback;
        }
    }

    // ─── Flow Invocable: AI Deal Analysis (single invocable) ─────
    // Apex allows only ONE @InvocableMethod per class, so this one method
    // serves BOTH modes via the request's Mode field:
    //   • Mode = 'Loss' (default): forensic loss analysis. Maps the root cause
    //     to picklist values and writes CL_Reason_AI__c, CL_Narrative_AI__c,
    //     and Final_Competitor__c back to the Opportunity.
    //   • Mode = 'Win': win analysis. Returns a long-form narrative in
    //     AI Summary (+ AI Activity Insights). No loss fields, no write-back —
    //     the caller maps AI Summary to its own long-text field.
    @InvocableMethod(
        label='Get AI Deal Analysis'
        description='Runs Claude analysis on an opportunity. Mode=Loss (default) writes forensic loss fields; Mode=Win returns a win narrative in AI Summary.'
        category='Deal Score'
    )
    public static List<ForensicResult> getForensicAnalysis(List<ForensicRequest> requests) {
        List<ForensicResult> results = new List<ForensicResult>();
        List<Opportunity> toUpdate = new List<Opportunity>();

        // Phase 1: all callouts + analysis. NO DML here — a mid-loop update would
        // make the next request's callout throw "uncommitted work pending" (this is
        // exactly what broke batch scopes > 1). We collect the updates and flush once
        // after every callout is done.
        for (ForensicRequest req : requests) {
            ForensicResult res = new ForensicResult();
            Boolean isWin = req.mode != null && req.mode.equalsIgnoreCase('Win');
            try {
                DealAnalysis analysis = isWin
                    ? runWinAnalysis(req.opportunityId)
                    : runLossAnalysis(req.opportunityId);

                res.summary = analysis.summary;
                res.activityInsights = analysis.activityInsights;
                res.clReason = analysis.clReason;         // null in Win mode
                res.clNarrative = analysis.clNarrative;   // null in Win mode
                res.clCompetitor = analysis.clCompetitor; // null in Win mode
                res.nextStep = analysis.nextStep;
                res.confidence = analysis.confidence;
                res.evidenceTier = analysis.evidenceTier;
                res.clReasonMatchesRep = analysis.clReasonMatchesRep; // null in Win mode
                res.success = true;

                // Build (do not commit) the write-back for this opp.
                // Loss fields: Apex owns these in Loss mode (unchanged live behavior,
                // and the backfill relies on it since it doesn't run through the Flow).
                // New AI fields: written ONLY when the request opts in via
                // writeBackNewFields, so the live Flow remains the sole writer for
                // go-forward deals. The backfill sets the flag; the Flow leaves it off.
                Boolean writeNew = (req.writeBackNewFields == true);
                Opportunity opp = new Opportunity(Id = req.opportunityId);
                Boolean needsUpdate = false;

                if (!isWin) {
                    if (String.isNotBlank(res.clReason)) {
                        opp.CL_Reason_AI__c = res.clReason;
                        needsUpdate = true;
                    }
                    if (String.isNotBlank(res.clNarrative)) {
                        opp.CL_Narrative_AI__c = res.clNarrative;
                        needsUpdate = true;
                    }
                    if (String.isNotBlank(res.clCompetitor)) {
                        opp.Final_Competitor__c = res.clCompetitor;
                        needsUpdate = true;
                    }
                }

                if (writeNew) {
                    if (String.isNotBlank(res.nextStep)) {
                        opp.Next_Step_AI__c = res.nextStep;
                        needsUpdate = true;
                    }
                    if (String.isNotBlank(res.evidenceTier)) {
                        opp.Evidence_Tier_AI__c = res.evidenceTier;
                        needsUpdate = true;
                    }
                    if (String.isNotBlank(res.confidence)) {
                        // Mode selects the confidence field.
                        if (isWin) {
                            opp.CW_Confidence_AI__c = res.confidence;
                        } else {
                            opp.CL_Confidence_AI__c = res.confidence;
                        }
                        needsUpdate = true;
                    }
                    // cl_reason_matches_rep is intentionally NOT persisted here — it's
                    // set going forward via Flow, not backfilled.
                }

                if (needsUpdate) {
                    toUpdate.add(opp);
                }

            } catch (Exception e) {
                res.success = false;
                res.summary = (isWin ? 'AI win analysis failed: ' : 'AI analysis failed: ') + e.getMessage();
                res.clReason = null;
                res.clNarrative = null;
                res.clCompetitor = null;
            }
            results.add(res);
        }

        // Phase 2: one bulk write after all callouts. allOrNone=false so a single
        // record's validation failure doesn't drop the rest of a batch chunk.
        if (!toUpdate.isEmpty()) {
            Database.update(toUpdate, false);
        }

        return results;
    }

    // Flow input
    public class ForensicRequest {
        @InvocableVariable(required=true label='Opportunity ID')
        public Id opportunityId;

        @InvocableVariable(label='Mode' description='Win or Loss. Loss (default) runs forensic loss analysis and writes loss fields; Win returns a win narrative in AI Summary with no write-back.')
        public String mode;

        @InvocableVariable(label='Write Back New AI Fields' description='When true, also writes Next_Step_AI__c, Evidence_Tier_AI__c, and the mode-specific confidence field (CL_/CW_Confidence_AI__c). Leave false (default) when a Flow handles the write; the backfill sets it true.')
        public Boolean writeBackNewFields;
    }

    // Flow output — all fields available as Flow variables
    public class ForensicResult {
        @InvocableVariable(label='Success')
        public Boolean success;

        @InvocableVariable(label='AI Loss Reason (Picklist Value)')
        public String clReason;

        @InvocableVariable(label='AI Loss Narrative')
        public String clNarrative;

        @InvocableVariable(label='AI Final Competitor (Picklist Value)')
        public String clCompetitor;

        @InvocableVariable(label='AI Summary')
        public String summary;

        @InvocableVariable(label='AI Activity Insights')
        public String activityInsights;

        @InvocableVariable(label='AI Next Step')
        public String nextStep;

        @InvocableVariable(label='AI Confidence (High/Medium/Low)')
        public String confidence;

        @InvocableVariable(label='AI Evidence Tier')
        public String evidenceTier;

        @InvocableVariable(label='AI Reason Matches Rep (Loss only)')
        public Boolean clReasonMatchesRep;
    }

    // ─── Loss analysis: build forensic context, call Claude, parse ──
    private static DealAnalysis runLossAnalysis(Id oppId) {
        // Build context; force closed-lost framing regardless of current stage.
        DealContext dc = buildContext(oppId, 0, 'Closed Lost');
        String context = dc.text;

        // Inject a pre-close header only for a still-open deal (pre-close use).
        if (!context.contains('Status: CLOSED LOST') && !context.contains('Status: CLOSED WON')) {
            context += '\n## Deal Outcome\nStatus: CLOSED LOST\n';
            context += 'ANALYSIS MODE: Pre-close loss review — this deal is about to be marked lost. ';
            context += 'Analyze all available data to determine WHY this deal should be marked as lost.\n';
        }

        // Mode is explicit — routing never depends on scanning the context string.
        String aiResponse = callClaude(context, 'LOST');
        return parseResponse(aiResponse);
    }

    // ─── Win analysis: build won-framed context, call Claude, parse ─
    private static DealAnalysis runWinAnalysis(Id oppId) {
        // Build context; force won framing regardless of current stage.
        DealContext dc = buildContext(oppId, 100, 'Closed Won');
        String context = dc.text;

        // Inject win header only for a still-open deal (pre-close use).
        if (!context.contains('Status: CLOSED WON') && !context.contains('Status: CLOSED LOST')) {
            context += '\n## Deal Outcome\nStatus: CLOSED WON\n';
            context += 'ANALYSIS MODE: Win analysis — the rep is marking this deal as won. ';
            context += 'Analyze all available data to determine WHY this deal was won.\n';
        }

        // Mode is explicit — routing never depends on scanning the context string.
        String aiResponse = callClaude(context, 'WON');
        return parseResponse(aiResponse);
    }

    // ─── Build context string with opp data + activities ──────────
    private static DealContext buildContext(Id oppId, Decimal scorePercent, String tierAction) {
        // Opportunity fields
        Opportunity opp = [
            SELECT AccountId, Name, StageName, Amount, CloseDate, CreatedDate,
                   Segment__c, Business_Type1__c, LeadSourceType__c, LeadSource,
                   ELA__c, DQ_Demo__c, No_of_Employees__c,
                   First_Meeting_Completed__c, Pilot_Completed__c,
                   Deal_Description__c, Purchase_Driver__c, Key_Risks__c,
                   Success_Criteria__c, Gong__MainCompetitors__c,
                   NextStep, Next_Step_Date__c, Notes__c,
                   IsClosed, IsWon,
                   CL_Primary_Reason__c, CL_Secondary_Reason__c,
                   Loss_Reason_Detail__c, CL_Notes__c,
                   Close_Lost_from_Stage__c, Final_Competitor__c,
                   Account.Name, Account.Industry,
                   Owner.Name
            FROM Opportunity
            WHERE Id = :oppId
            LIMIT 1
        ];

        Integer dealAgeDays = opp.CreatedDate.date().daysBetween(
            opp.IsClosed && opp.CloseDate != null ? opp.CloseDate : Date.today()
        );

        // Close date context — explicit past/future and days remaining
        String closeDateContext;
        if (opp.CloseDate == null) {
            closeDateContext = 'Not set';
        } else {
            Integer daysUntilClose = Date.today().daysBetween(opp.CloseDate);
            if (daysUntilClose > 0) {
                closeDateContext = String.valueOf(opp.CloseDate)
                    + ' (IN ' + daysUntilClose + ' DAYS — has NOT passed yet)';
            } else if (daysUntilClose == 0) {
                closeDateContext = String.valueOf(opp.CloseDate) + ' (TODAY)';
            } else {
                closeDateContext = String.valueOf(opp.CloseDate)
                    + ' (OVERDUE by ' + Math.abs(daysUntilClose) + ' days — close date has passed)';
            }
        }

        // Recent Tasks (last 30 days) — emails, calls, meetings
        List<Task> tasks = [
            SELECT Subject, Description, Type, TaskSubtype, ActivityDate, Status,
                   Gong__Call_Outcome__c
            FROM Task
            WHERE WhatId = :oppId
              AND ActivityDate >= :Date.today().addDays(-30)
            ORDER BY ActivityDate DESC
            LIMIT 15
        ];

        // Recent Events (includes Grain and Granola meeting notes)
        List<Event> events = [
            SELECT Subject, Description, StartDateTime
            FROM Event
            WHERE WhatId = :oppId
              AND StartDateTime >= :DateTime.now().addDays(-180)
            ORDER BY StartDateTime DESC
            LIMIT 8
        ];

        // Gong calls tied to this opportunity (last 3 calls)
        List<Gong__Gong_Call__c> gongCalls = [
            SELECT Name, Gong__Call_Brief__c, Gong__Call_Highlights_Next_Steps__c,
                   Gong__Call_Key_Points__c, Gong__Call_Outcome__c,
                   Gong__Call_Start__c, Gong__Call_Duration__c,
                   Gong__Participants_Emails__c, Gong__Direction__c,
                   Gong__Talk_Time_Us__c, Gong__Talk_Time_Them__c,
                   Gong__Related_Trackers_json__c, Gong__Related_Topics_json__c
            FROM Gong__Gong_Call__c
            WHERE Gong__Primary_Opportunity__c = :oppId
            ORDER BY Gong__Call_Start__c DESC
            LIMIT 3
        ];

        // Auto-logged emails on this opp, last 14 days. Pull a bit wide, then
        // prioritize inbound (subject tagged [IN], or the native Incoming flag)
        // over outbound and cap at 10 — inbound is the customer's own words.
        Datetime emailCutoff = Datetime.now().addDays(-14);
        List<EmailMessage> emailsRaw = [
            SELECT Subject, TextBody, Incoming, MessageDate, FromAddress, ToAddress
            FROM EmailMessage
            WHERE RelatedToId = :oppId
              AND MessageDate >= :emailCutoff
            ORDER BY MessageDate DESC
            LIMIT 30
        ];
        List<EmailMessage> inbound = new List<EmailMessage>();
        List<EmailMessage> outbound = new List<EmailMessage>();
        for (EmailMessage em : emailsRaw) {
            String subj = (em.Subject == null ? '' : em.Subject).toUpperCase();
            Boolean isIn = subj.contains('[IN]')
                || (!subj.contains('[OUT]') && em.Incoming == true);
            if (isIn) { inbound.add(em); } else { outbound.add(em); }
        }
        List<EmailMessage> emails = new List<EmailMessage>();
        for (EmailMessage em : inbound) {        // inbound first (already newest-first)
            if (emails.size() >= 10) break;
            emails.add(em);
        }
        for (EmailMessage em : outbound) {       // then fill remaining slots with outbound
            if (emails.size() >= 10) break;
            emails.add(em);
        }

        // Build the prompt context
        String ctx = '## Today\'s Date: ' + String.valueOf(Date.today()) + '\n\n';
        ctx += '## Opportunity Details\n';
        ctx += 'Name: ' + opp.Name + '\n';
        ctx += 'Account: ' + (opp.Account != null ? opp.Account.Name : 'Unknown') + '\n';
        ctx += 'Stage: ' + opp.StageName + '\n';
        ctx += 'Amount: ' + (opp.Amount != null ? '$' + opp.Amount.format() : 'Not set') + '\n';
        ctx += 'Segment: ' + nvl(opp.Segment__c) + '\n';
        ctx += 'Business Type: ' + nvl(opp.Business_Type1__c) + '\n';
        ctx += 'Lead Source: ' + nvl(opp.LeadSourceType__c) + ' / ' + nvl(opp.LeadSource) + '\n';
        ctx += 'Deal Age: ' + dealAgeDays + ' days\n';
        ctx += 'Close Date: ' + closeDateContext + '\n';
        ctx += 'Owner: ' + (opp.Owner != null ? opp.Owner.Name : 'Unknown') + '\n';
        ctx += 'ELA: ' + opp.ELA__c + '\n';
        ctx += 'First Meeting Completed: ' + opp.First_Meeting_Completed__c + '\n';
        ctx += 'Pilot Completed: ' + nvl(opp.Pilot_Completed__c) + '\n';
        ctx += 'Competitors: ' + nvl(opp.Gong__MainCompetitors__c) + '\n';
        ctx += 'Next Step: ' + nvl(opp.NextStep) + '\n';
        ctx += 'Key Risks: ' + nvl(opp.Key_Risks__c) + '\n';
        ctx += 'Purchase Driver: ' + nvl(opp.Purchase_Driver__c) + '\n';
        ctx += 'Success Criteria: ' + nvl(opp.Success_Criteria__c) + '\n';

        // Rep-authored free-text notes. This is where the owner records context that
        // isn't captured elsewhere (e.g. meetings that couldn't be recorded or weren't
        // logged as activities), so treat it as first-hand, authoritative context.
        if (String.isNotBlank(opp.Notes__c)) {
            ctx += '\n## [RepNotes] Deal Notes from the Opportunity Owner\n';
            ctx += opp.Notes__c.replaceAll('<br>', '\n').replaceAll('<[^>]+>', '') + '\n';
        }

        ctx += '\n## Model Score\n';
        ctx += 'Win Probability: ' + scorePercent + '%\n';
        ctx += 'Tier: ' + tierAction + '\n';

        // Forensic context for closed deals
        if (opp.IsClosed) {
            ctx += '\n## Deal Outcome\n';
            ctx += 'Status: ' + (opp.IsWon ? 'CLOSED WON' : 'CLOSED LOST') + '\n';
            ctx += 'Days to Close: ' + dealAgeDays + '\n';
            if (!opp.IsWon) {
                ctx += 'Primary Loss Reason: ' + nvl(opp.CL_Primary_Reason__c) + '\n';
                ctx += 'Secondary Loss Reason: ' + nvl(opp.CL_Secondary_Reason__c) + '\n';
                ctx += 'Loss Details: ' + nvl(opp.Loss_Reason_Detail__c) + '\n';
                ctx += 'Loss Notes: ' + nvl(opp.CL_Notes__c) + '\n';
                ctx += 'Lost from Stage: ' + nvl(opp.Close_Lost_from_Stage__c) + '\n';
                ctx += 'Final Competitor: ' + nvl(opp.Final_Competitor__c) + '\n';
            }
        }

        ctx += '\n## Recent Activities (Last 30 Days)\n';
        if (tasks.isEmpty()) {
            ctx += 'No activities logged in the last 30 days.\n';
        } else {
            for (Task t : tasks) {
                ctx += '- [' + t.ActivityDate + '] ';
                ctx += (t.Type != null ? t.Type : (t.TaskSubtype != null ? t.TaskSubtype : 'Activity'));
                ctx += ': ' + nvl(t.Subject) + '\n';
                if (t.Gong__Call_Outcome__c != null) {
                    ctx += '  Call Outcome: ' + truncate(t.Gong__Call_Outcome__c, 300) + '\n';
                }
                if (t.Description != null) {
                    ctx += '  Detail: ' + truncate(t.Description, 200) + '\n';
                }
            }
        }

        ctx += '\n## [Emails] Auto-Logged Emails (Last 14 Days, inbound prioritized)\n';
        if (emails.isEmpty()) {
            ctx += 'No emails logged in the last 14 days.\n';
        } else {
            for (EmailMessage em : emails) {
                String subj = (em.Subject == null ? '' : em.Subject);
                String dir = subj.toUpperCase().contains('[IN]') ? 'INBOUND (from customer)'
                    : subj.toUpperCase().contains('[OUT]') ? 'OUTBOUND (from us)'
                    : (em.Incoming == true ? 'INBOUND (from customer)' : 'OUTBOUND (from us)');
                String d = em.MessageDate != null ? String.valueOf(em.MessageDate.date()) : 'no date';
                ctx += '- [' + d + '] ' + dir + ' | ' + subj + '\n';
                if (String.isNotBlank(em.TextBody)) {
                    // Strip quoted reply history (lines starting with ">") and signatures noise,
                    // collapse whitespace, and cap length to keep the prompt lean.
                    String body = em.TextBody
                        .replaceAll('(?m)^>.*$', ' ')       // quoted lines
                        .replaceAll('\\s+', ' ')
                        .trim();
                    ctx += '  ' + truncate(body, 350) + '\n';
                }
            }
        }

        ctx += '\n## Recent Meetings (includes Grain & Granola recordings)\n';
        if (events.isEmpty()) {
            ctx += 'No meetings recorded.\n';
        } else {
            for (Event e : events) {
                String subj = nvl(e.Subject);
                Boolean isGranola = subj.contains('Granola');
                Boolean isGrain = false;
                if (e.Description != null && e.Description.contains('grain.com')) {
                    isGrain = true;
                }
                String source = isGranola ? ' [Granola]' : (isGrain ? ' [Grain]' : '');
                ctx += '- [' + e.StartDateTime.format() + ']' + source + ' ' + subj + '\n';
                if (e.Description != null) {
                    // Granola notes are very rich — allow more space
                    Integer maxLen = isGranola ? 3000 : 1500;
                    ctx += '  Notes: ' + truncate(e.Description, maxLen) + '\n';
                }
            }
        }

        // Gong call intelligence
        ctx += '\n## Gong Call Intelligence\n';
        if (gongCalls.isEmpty()) {
            ctx += 'No Gong calls recorded for this opportunity.\n';
        } else {
            for (Gong__Gong_Call__c g : gongCalls) {
                ctx += '\n### Call: ' + nvl(g.Name) + ' (' + (g.Gong__Call_Start__c != null ? g.Gong__Call_Start__c.format() : 'unknown date') + ', ' + nvl(g.Gong__Call_Duration__c) + ')\n';
                ctx += 'Participants: ' + nvl(g.Gong__Participants_Emails__c) + '\n';

                if (g.Gong__Call_Brief__c != null) {
                    ctx += 'Brief: ' + truncate(g.Gong__Call_Brief__c, 500) + '\n';
                }
                if (g.Gong__Call_Key_Points__c != null) {
                    String kp = g.Gong__Call_Key_Points__c.replaceAll('<br>', '\n').replaceAll('<[^>]+>', '');
                    ctx += 'Key Points: ' + truncate(kp, 1000) + '\n';
                }
                if (g.Gong__Call_Highlights_Next_Steps__c != null) {
                    String ns = g.Gong__Call_Highlights_Next_Steps__c.replaceAll('<br>', '\n').replaceAll('<[^>]+>', '');
                    ctx += 'Next Steps: ' + truncate(ns, 500) + '\n';
                }
                if (g.Gong__Call_Outcome__c != null) {
                    ctx += 'Outcome: ' + g.Gong__Call_Outcome__c + '\n';
                }

                // Parse SMART trackers for MEDDPICC signals
                if (g.Gong__Related_Trackers_json__c != null) {
                    ctx += 'Qualification Signals (from conversation analysis):\n';
                    List<Object> trackers = (List<Object>) JSON.deserializeUntyped(g.Gong__Related_Trackers_json__c);
                    for (Object obj : trackers) {
                        Map<String, Object> tracker = (Map<String, Object>) obj;
                        String tName = (String) tracker.get('Name');
                        Object tCount = tracker.get('Gong__Tracker_Occurrences__c');
                        String tPhrase = (String) tracker.get('Gong__Tracker_Phrase__c');
                        if (tName != null && tName.startsWith('[SMART]')) {
                            ctx += '  - ' + tName.replace('[SMART] ', '') + ': ' + tCount + ' mentions\n';
                        } else if (tName != null && (tName.contains('Budget') || tName.contains('Pricing') || tName.contains('Competitor'))) {
                            String detail = tPhrase != null ? ' (' + tPhrase + ')' : '';
                            ctx += '  - ' + tName + detail + ': ' + tCount + ' mentions\n';
                        }
                    }
                }
            }
        }

        // ── Account history: prior closed opps on the same account ──
        // Labeled [AccountHistory] and worded WON/LOST (never "Status: CLOSED ...")
        // so it can't be mistaken for THIS opp's outcome. Routing uses explicit
        // mode anyway, but the clean wording keeps the model unambiguous too.
        if (opp.AccountId != null) {
            List<Opportunity> accountHistory = [
                SELECT Name, IsWon, Amount, CloseDate,
                       CL_Primary_Reason__c, Final_Competitor__c
                FROM Opportunity
                WHERE AccountId = :opp.AccountId
                  AND Id != :oppId
                  AND IsClosed = true
                ORDER BY CloseDate DESC
                LIMIT 10
            ];
            if (!accountHistory.isEmpty()) {
                ctx += '\n## [AccountHistory] Prior Closed Opportunities on This Account\n';
                for (Opportunity h : accountHistory) {
                    ctx += '- [' + (h.CloseDate != null ? String.valueOf(h.CloseDate) : 'no date') + '] '
                        + (h.IsWon ? 'WON' : 'LOST') + ' — ' + nvl(h.Name)
                        + (h.Amount != null ? ' — $' + h.Amount.format() : '');
                    if (!h.IsWon) {
                        ctx += ' — Reason: ' + nvl(h.CL_Primary_Reason__c)
                            + (String.isNotBlank(h.Final_Competitor__c) ? ', Competitor: ' + h.Final_Competitor__c : '');
                    }
                    ctx += '\n';
                }
            }
        }

        DealContext dc = new DealContext();
        dc.text = ctx;
        dc.mode = !opp.IsClosed ? 'ACTIVE' : (opp.IsWon ? 'WON' : 'LOST');
        return dc;
    }

    // Context payload plus the resolved analysis mode for this opportunity.
    private class DealContext {
        String text;
        String mode; // 'ACTIVE' | 'WON' | 'LOST'
    }

    // ─── Call Claude API via Named Credential ─────────────────────
    // mode: 'WON' | 'LOST' | 'ACTIVE'. Passed explicitly so routing NEVER depends
    // on string-scanning the context — critical now that [AccountHistory] can
    // contain a prior WON/LOST round that a text scan would misread as this deal.
    private static String callClaude(String context, String mode) {
        Boolean isForensic = (mode == 'WON' || mode == 'LOST');
        Boolean isWon = (mode == 'WON');

        String systemPrompt;

        if (isForensic) {
            systemPrompt = 'Today\'s date is ' + String.valueOf(Date.today()) + '. '
                + 'You are producing a professional, objective ' + (isWon ? 'win' : 'loss') + ' review for this deal. '
                + 'Be specific and evidence-based, and keep the tone measured and constructive. '
                + 'Reference people, dates, and conversation details where the data supports it. '
                + 'Explain the outcome in terms of deal dynamics, buyer circumstances, and market factors — '
                + 'not individual performance. Do not criticize, judge, or assign fault to the sales rep.\n\n'
                + 'DATA SOURCES: [Granola] = structured meeting notes. [Grain] = meeting summaries. '
                + 'Gong Call Intelligence = MEDDPICC signals. Tasks = email engagement. '
                + '[Emails] = auto-logged emails from the last 14 days; INBOUND messages are the customer\'s own words '
                + 'and are the strongest signal of buyer intent, objections, and sentiment. '
                + '[RepNotes] = free-text notes written by the opportunity owner. '
                + '[AccountHistory] = prior closed opportunities on this same account, if provided.\n\n'
                + 'GROUNDING RULES:\n'
                + '- Only reference people, dates, competitors, and facts that appear in the supplied data. '
                + 'Never invent a champion, meeting, price, or competitor. If something is unknown, say it is not in the record.\n'
                + '- [RepNotes], when present, is the owner\'s own first-hand account and often fills gaps the system data misses '
                + '(for example, a meeting that could not be recorded or was never logged as an activity). Treat it as authoritative '
                + 'context, weight it accordingly, and reconcile it with the other sources rather than overriding it. If [RepNotes] '
                + 'describes activity that does not appear elsewhere, take that as evidence the record is incomplete — not as a contradiction.\n'
                + '- The record may be INCOMPLETE. Not every interaction is captured: some meetings cannot be recorded '
                + '(for example, a customer may prohibit recording, including key sessions with senior stakeholders), and '
                + 'notes are not always logged. Treat the supplied data as a partial view. Where the trail is sparse, '
                + 'explicitly acknowledge that additional meetings may have taken place without being logged and that the '
                + 'full story may not be known — do NOT assume that missing data means nothing happened or that the rep was inactive.\n'
                + '- If the record is THIN (no calls, no meetings, sparse activity), do NOT pad with speculation. '
                + 'Note plainly what evidence is missing, allow that meetings may have occurred without being logged, '
                + 'and give a shorter, appropriately hedged summary. A thin-record deal still gets a summary.\n'
                + '- If [AccountHistory] is provided, incorporate prior-round outcomes, renames, and cross-sell context.\n\n';

            if (isWon) {
                systemPrompt += 'CLOSED WON — Analyze WHY the customer purchased:\n'
                    + '- What drove the decision? Reference specific conversations and turning points.\n'
                    + '- How did the champion navigate internal approval?\n'
                    + '- What was the competitive dynamic? What differentiated us?\n'
                    + '- What MEDDPICC elements were strongest?\n'
                    + '- PRODUCT SIGNALS: Identify the SPECIFIC product features, capabilities, or workflows that drove the win. '
                    + 'Name them concretely (e.g. a particular integration, answer/output quality on a real question, a specific '
                    + 'screen, workflow, or data source), and tie each to the customer reaction it produced — positive sentiment, '
                    + 'a demo or POV "aha" moment, or a stated reason it beat the alternative. Quote the customer where the data '
                    + 'allows. Ground every feature in the record (Gong highlights, [Emails] inbound, meeting notes, [RepNotes]); '
                    + 'do NOT invent capabilities.\n'
                    + '- State the deal economics: ACV/seat count/term and any discount or concession.\n\n';
            } else {
                systemPrompt += 'CLOSED LOST — Analyze WHY we lost. Look past the coded loss reason to the underlying driver:\n'
                    + '- What was the primary driver: product fit, price/budget, timing, competition, authority, or external business change?\n'
                    + '- Which MEDDPICC elements appear established in the record, and which are not evidenced? '
                    + '(Treat "not evidenced" as a possible logging gap, not necessarily a gap in the deal itself.)\n'
                    + '- Were there signals in the logged conversations that point to the outcome? '
                    + 'Frame these as observations, not as things anyone failed to catch or act on.\n'
                    + '- Were stated success criteria or metrics left unmet, per the record?\n'
                    + '- PRODUCT SIGNALS: Identify any SPECIFIC product features, capabilities, or gaps that shaped the outcome. '
                    + 'Name them concretely and tie each to the reaction it produced — a missing capability the buyer needed, '
                    + 'functionality that underwhelmed in a demo or POV, an integration or data-coverage gap, or a feature that '
                    + 'drew negative sentiment. Equally, call out features that DID land well even though the deal was lost, since '
                    + 'that signals product strength independent of the loss. Quote the customer where the data allows. Ground every '
                    + 'feature in the record (Gong, [Emails] inbound, notes); do NOT invent capabilities, and keep the framing about '
                    + 'product fit, not blame.\n'
                    + '- If the loss appears driven by externalities outside the team\'s control, say so clearly and without hedging.\n\n'
                    + 'IMPORTANT: You MUST also map the root cause to EXACTLY ONE of these picklist values:\n'
                    + 'Bad Fit Disqualified, Budget Financial, Business Change, Competitive Loss, '
                    + 'Duplicate, No Need, No Show / Buyer Canceled, Product / Technical Gap, '
                    + 'Security Compliance, Timing Priority, Wrong Authority\n'
                    + 'Choose the BEST match based on your analysis of the data, not just the rep\'s coded reason.\n\n'
                    + 'If a competitor was involved, map to EXACTLY ONE of these picklist values (or null if none):\n'
                    + 'AlphaSense, BlueFlame, ChatGPT, Claude, Hebbia, Internal Build, ModelML, Perplexity\n'
                    + 'Choose based on Gong tracker data, meeting notes, and email mentions — not just the existing field value.\n\n';
            }

            // ── Field guidance shared across won/lost ──────────────
            systemPrompt += 'FIELD RULES:\n'
                + '- TONE: professional, objective, and constructive throughout. Attribute the outcome to deal circumstances, '
                + 'buyer behavior, and market factors — not to the rep. Avoid blaming or judgmental phrasing '
                + '("the rep failed to", "should have", "neglected", "dropped the ball"). Where the record is thin, prefer '
                + '"not captured in the record" over language that implies inaction, and note that unlogged meetings may exist.\n'
                + '- "summary" is the LONG-FORM analysis: one or two full paragraphs (roughly 4-8 sentences), '
                + 'specific and evidence-based. It MUST include a product dimension: call out by name the specific product '
                + 'features, capabilities, workflows, or gaps that drove sentiment (positive or negative) or produced "aha" '
                + 'moments, and tie each to the customer reaction and how it influenced the outcome. Only name features that '
                + 'actually appear in the data.\n'
                + '- "cl_narrative" is a SEPARATE, standalone statement written as one or two COMPLETE sentences, '
                + 'at most 240 characters. It is stored in its own short field and read on its own, so it MUST be '
                + 'fully coherent and self-contained. Do NOT make it a truncated or front-clipped copy of the summary, '
                + 'and never let it end mid-thought.\n'
                + '- "next_step" is the SINGLE most important recommended action to re-engage or expand this account, '
                + 'written as one concrete, specific sentence (who to contact, what to do, and any trigger/date to watch). '
                + 'Not a generic platitude.\n'
                + '- "evidence_tier" describes the STRONGEST evidence you actually used, e.g. "Deep (Gong + SF activity)", '
                + '"Deep (SF activity only)", or "Signal-based (SF fields, no calls)".\n'
                + '- "confidence" is High / Medium / Low, reflecting how much corroborating evidence supported your root cause.\n'
                + '- "cl_reason_matches_rep" is true when your chosen cl_reason aligns with the rep-coded "Primary Loss Reason" '
                + 'in the supplied data, and false when your analysis points to a different root cause. When false, briefly note '
                + 'the divergence in the summary.\n\n';

            String responseFormat;
            if (isWon) {
                responseFormat = '{'
                    + '"summary":"One or two full paragraphs (4-8 sentences) on why the customer purchased: the decision drivers, key turning points, competitive dynamic, strongest MEDDPICC elements, and the deal economics, citing specific evidence. Explicitly name the specific product features/capabilities that resonated and the aha moment or positive sentiment each produced.",'
                    + '"activity_insights":"...",'
                    + '"recommendations":["...","...","..."],'
                    + '"next_step":"The single most important expansion/retention action, one concrete sentence.",'
                    + '"evidence_tier":"Strongest evidence source used.",'
                    + '"confidence":"High | Medium | Low"}';
            } else {
                responseFormat = '{'
                    + '"summary":"One or two full paragraphs (4-8 sentences) on why the deal was lost: the root cause, contributing factors, the turning points, and the most important supporting evidence from calls, meetings, and emails. Explicitly name any specific product features/capabilities or gaps that shaped sentiment or the outcome (positive or negative), with the customer reaction to each. This is the long-form analysis.",'
                    + '"activity_insights":"...",'
                    + '"recommendations":["...","...","..."],'
                    + '"next_step":"The single most important re-engagement action, one concrete sentence with who/what/when.",'
                    + '"cl_reason":"EXACTLY one of the loss reason picklist values",'
                    + '"cl_narrative":"A standalone, plain-English statement of the SINGLE root cause, written as one or two COMPLETE sentences and at most 240 characters. Fully coherent on its own — NOT a shortened copy of the summary and NOT cut off mid-thought.",'
                    + '"cl_competitor":"EXACTLY one competitor picklist value, or null if no competitor involved",'
                    + '"cl_reason_matches_rep":true,'
                    + '"evidence_tier":"Strongest evidence source used.",'
                    + '"confidence":"High | Medium | Low"}';
            }
            systemPrompt += 'Respond in this exact JSON format (no markdown, no backticks):\n' + responseFormat;
        } else {
            systemPrompt = 'Today\'s date is ' + String.valueOf(Date.today()) + '. '
                + 'You are a deal intelligence analyst embedded in Salesforce. '
                + 'Your job is to surface what is GOING WELL, what NEEDS ATTENTION, and what the rep should DO NEXT. '
                + 'Be specific — reference people, dates, quotes, and data points. Never be generic.\n\n'
                + 'CRITICAL: The Close Date field includes explicit context about whether it has passed — trust it exactly.\n\n'
                + 'DATA SOURCES: [Granola] = structured meeting notes. [Grain] = meeting summaries. '
                + 'Gong Call Intelligence = MEDDPICC signals from conversation analysis. Tasks = email engagement.\n\n'
                + 'ANALYZE THESE DIMENSIONS:\n'
                + '1. DISCOVERY PROGRESS: Has the rep uncovered pain, metrics, decision process, and economic buyer? '
                + 'What MEDDPICC elements are strong vs missing?\n'
                + '2. CUSTOMER SENTIMENT: Is the prospect showing genuine excitement, curiosity, or skepticism? '
                + 'Look for positive language, repeat engagement, stakeholder expansion vs objections, silence, and ghosting.\n'
                + '3. COMPETITIVE DYNAMICS: Are competitors mentioned? What is the prospect comparing us to? '
                + 'Are we differentiated on their decision criteria?\n'
                + '4. DEAL VELOCITY: Is activity consistent or declining? Is the deal aging beyond its expected cycle? '
                + 'Is the close date realistic given the current stage?\n'
                + '5. STAGE FIT: Does the activity match the current stage? Stages: 1-Demo, 2-Discovery, 3-POV, 4-Proposal, 5-Contracting.\n\n'
                + 'Respond in this exact JSON format (no markdown, no backticks):\n'
                + '{"summary": "2-3 sentence overview of where this deal stands and overall sentiment",'
                + '"positive_signals": ["What is going well — each a specific, grounded observation from the data (2-5 items)"],'
                + '"concerns": ["What needs attention — each a specific risk, gap, or warning sign (2-5 items)"],'
                + '"recommendations": ["Concrete next step 1 — reference specific people or actions","Step 2","Step 3"]}';
        }

        String userMessage = context;

        // Build request body
        JSONGenerator gen = JSON.createGenerator(true);
        gen.writeStartObject();
        gen.writeStringField('model', MODEL);
        // 800 truncated the forensic JSON mid-string (parse failed at the cutoff);
        // give the model room to close the object. Bumped to 2500 now that the
        // summary is a 1-2 paragraph narrative. Output still stays under this.
        gen.writeNumberField('max_tokens', 2500);

        // System prompt
        gen.writeFieldName('system');
        gen.writeString(systemPrompt);

        // Messages
        gen.writeFieldName('messages');
        gen.writeStartArray();
        gen.writeStartObject();
        gen.writeStringField('role', 'user');
        gen.writeStringField('content', userMessage);
        gen.writeEndObject();
        gen.writeEndArray();

        gen.writeEndObject();

        HttpRequest req = new HttpRequest();
        req.setEndpoint(NAMED_CREDENTIAL + '/v1/messages');
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(calloutTimeoutMs);
        req.setBody(gen.getAsString());

        Http http = new Http();
        HttpResponse res = http.send(req);

        if (res.getStatusCode() != 200) {
            throw new CalloutException('Claude API returned ' + res.getStatusCode() + ': ' + res.getBody());
        }

        // Extract text from response
        Map<String, Object> responseMap = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        List<Object> content = (List<Object>) responseMap.get('content');
        Map<String, Object> textBlock = (Map<String, Object>) content[0];
        return (String) textBlock.get('text');
    }

    // ─── Parse Claude's JSON response ─────────────────────────────
    private static DealAnalysis parseResponse(String jsonText) {
        // Strip any markdown backticks if present
        jsonText = jsonText.replace('```json', '').replace('```', '').trim();

        DealAnalysis analysis = new DealAnalysis();

        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(jsonText);
        analysis.summary = (String) parsed.get('summary');
        analysis.activityInsights = (String) parsed.get('activity_insights');

        analysis.recommendations = new List<String>();
        List<Object> recs = (List<Object>) parsed.get('recommendations');
        if (recs != null) {
            for (Object r : recs) {
                analysis.recommendations.add((String) r);
            }
        }

        // Positive signals and concerns (active deal mode)
        analysis.positiveSignals = new List<String>();
        List<Object> posSignals = (List<Object>) parsed.get('positive_signals');
        if (posSignals != null) {
            for (Object s : posSignals) {
                analysis.positiveSignals.add((String) s);
            }
        }

        analysis.concerns = new List<String>();
        List<Object> negSignals = (List<Object>) parsed.get('concerns');
        if (negSignals != null) {
            for (Object s : negSignals) {
                analysis.concerns.add((String) s);
            }
        }

        // Closed-lost forensic fields
        if (parsed.containsKey('cl_reason')) {
            analysis.clReason = (String) parsed.get('cl_reason');
        }
        if (parsed.containsKey('cl_narrative')) {
            // Fit the 255-char field without mangling the sentence. The model is told to
            // keep this under 240 chars and self-contained; clampNarrative is overflow
            // insurance only, and degrades on a sentence/word boundary rather than
            // cutting mid-thought.
            analysis.clNarrative = clampNarrative((String) parsed.get('cl_narrative'));
        }
        if (parsed.containsKey('cl_competitor')) {
            Object comp = parsed.get('cl_competitor');
            if (comp != null && comp instanceof String && String.isNotBlank((String) comp)) {
                analysis.clCompetitor = (String) comp;
            }
        }

        // New forensic outputs (present in both won/lost forensic responses,
        // absent from the active-deal response — containsKey guards handle that).
        if (parsed.containsKey('next_step')) {
            // Cap at 255 so it fits Next_Step_AI__c and doesn't overflow the Flow.
            analysis.nextStep = clampNarrative((String) parsed.get('next_step'));
        }
        if (parsed.containsKey('evidence_tier')) {
            analysis.evidenceTier = (String) parsed.get('evidence_tier');
        }
        if (parsed.containsKey('confidence')) {
            analysis.confidence = (String) parsed.get('confidence');
        }
        if (parsed.containsKey('cl_reason_matches_rep')) {
            Object m = parsed.get('cl_reason_matches_rep');
            if (m instanceof Boolean) {
                analysis.clReasonMatchesRep = (Boolean) m;
            } else if (m instanceof String) {
                analysis.clReasonMatchesRep = 'true'.equalsIgnoreCase((String) m);
            }
        }

        return analysis;
    }

    // ─── Response wrapper ─────────────────────────────────────────
    public class DealAnalysis {
        @AuraEnabled public String summary;
        @AuraEnabled public String activityInsights;
        @AuraEnabled public List<String> recommendations;
        @AuraEnabled public List<String> positiveSignals;
        @AuraEnabled public List<String> concerns;
        @AuraEnabled public String clReason;
        @AuraEnabled public String clNarrative;
        @AuraEnabled public String clCompetitor;
        @AuraEnabled public String nextStep;
        @AuraEnabled public String evidenceTier;
        @AuraEnabled public String confidence;
        @AuraEnabled public Boolean clReasonMatchesRep;
    }

    // ─── Task count for client-side model scoring ──────────────
    @AuraEnabled(cacheable=true)
    public static Integer getTaskCount(Id opportunityId) {
        return [SELECT COUNT() FROM Task WHERE WhatId = :opportunityId];
    }

    // ─── Momentum indicator ──────────────────────────────────────
    @AuraEnabled(cacheable=false)
    public static MomentumData getMomentum(Id opportunityId) {
        MomentumData m = new MomentumData();

        // Get activity dates for the last 90 days
        Date today = Date.today();
        List<Task> recentTasks = [
            SELECT ActivityDate FROM Task
            WHERE WhatId = :opportunityId AND ActivityDate != null
            ORDER BY ActivityDate DESC
            LIMIT 200
        ];

        if (recentTasks.isEmpty()) {
            m.direction = 'cold';
            m.label = 'No activities logged';
            m.daysSinceLastTouch = null;
            m.last7 = 0;
            m.prev7 = 0;
            return m;
        }

        // Compute windowed counts
        Integer last7 = 0;
        Integer prev7 = 0;
        Integer last14 = 0;
        Integer last30 = 0;
        Date lastTouchDate = recentTasks[0].ActivityDate;
        m.daysSinceLastTouch = lastTouchDate.daysBetween(today);

        // Find the gap before the most recent burst
        Date previousActivityDate = null;
        Integer gapBeforeBurst = 0;

        for (Integer i = 0; i < recentTasks.size(); i++) {
            Date d = recentTasks[i].ActivityDate;
            Integer daysAgo = d.daysBetween(today);

            if (daysAgo <= 7) last7++;
            if (daysAgo > 7 && daysAgo <= 14) prev7++;
            if (daysAgo <= 14) last14++;
            if (daysAgo <= 30) last30++;

            // Find the gap: look at the first activity outside the recent burst
            if (i > 0 && previousActivityDate != null && gapBeforeBurst == 0) {
                Integer daysBetween = d.daysBetween(previousActivityDate);
                if (daysBetween > 14) {
                    gapBeforeBurst = daysBetween;
                }
            }
            previousActivityDate = d;
        }

        m.last7 = last7;
        m.prev7 = prev7;

        // Determine direction and label
        if (m.daysSinceLastTouch > 14) {
            m.direction = 'cold';
            m.label = 'Gone dark — ' + m.daysSinceLastTouch + 'd since last touch';
        } else if (last7 > 0 && prev7 == 0 && gapBeforeBurst > 14) {
            m.direction = 'rising';
            m.label = 'Re-engaged after ' + gapBeforeBurst + 'd silence';
        } else if (last7 >= 3 && last7 >= prev7) {
            m.direction = 'rising';
            m.label = 'Active — ' + last7 + ' touchpoints this week';
        } else if (last14 > 0 && last7 > 0 && last7 < prev7) {
            m.direction = 'cooling';
            m.label = 'Activity slowing — ' + last7 + ' this week vs ' + prev7 + ' last week';
        } else if (last7 > 0) {
            m.direction = 'steady';
            m.label = 'Steady engagement — ' + last14 + ' touchpoints in 14d';
        } else if (last14 > 0) {
            m.direction = 'cooling';
            m.label = 'Cooling — last touch ' + m.daysSinceLastTouch + 'd ago';
        } else {
            m.direction = 'cold';
            m.label = 'Stalled — ' + m.daysSinceLastTouch + 'd since last touch';
        }

        return m;
    }

    public class MomentumData {
        @AuraEnabled public String direction;    // rising, steady, cooling, cold
        @AuraEnabled public String label;
        @AuraEnabled public Integer daysSinceLastTouch;
        @AuraEnabled public Integer last7;
        @AuraEnabled public Integer prev7;
    }

    // ─── Helpers ──────────────────────────────────────────────────
    private static String nvl(String val) {
        return val != null ? val : 'Not set';
    }

    private static String truncate(String val, Integer maxLen) {
        if (val == null) return '';
        return val.length() > maxLen ? val.substring(0, maxLen) + '...' : val;
    }

    // Keep the loss narrative a coherent, standalone statement within the 255-char field.
    // Prefers to end on a complete sentence; otherwise falls back to a whole-word boundary
    // with an ellipsis. Never cuts in the middle of a word. The prompt keeps the model under
    // 240 chars, so this is overflow insurance, not the primary length control.
    private static String clampNarrative(String val) {
        Integer cap = 255;
        if (String.isBlank(val)) return val;
        val = val.trim();
        if (val.length() <= cap) return val;

        String window = val.substring(0, cap);
        Integer cut = -1;
        for (String term : new List<String>{'. ', '! ', '? '}) {
            Integer idx = window.lastIndexOf(term);
            if (idx > cut) cut = idx;
        }
        // End on the last complete sentence if one sits past the halfway mark.
        if (cut > cap / 2) {
            return window.substring(0, cut + 1).trim();
        }
        // Otherwise end on the last whole word, leaving room for the ellipsis.
        String wordWindow = val.substring(0, cap - 3);
        Integer lastSpace = wordWindow.lastIndexOf(' ');
        if (lastSpace > 0) {
            return wordWindow.substring(0, lastSpace).trim() + '...';
        }
        return window.trim(); // single oversized token — last resort
    }
}