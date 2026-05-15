public with sharing class RogoUsageInsightsController {

    @TestVisible private static String bearerTokenOverride;

    public class InsightsJob {
        @AuraEnabled public String jobId;
        @AuraEnabled public String status;
        @AuraEnabled public Integer nextPollAfterMs;
    }

    public class InsightsResult {
        @AuraEnabled public String status;
        @AuraEnabled public Decimal progress;
        @AuraEnabled public Integer nextPollAfterMs;
        @AuraEnabled public Metrics metrics;
        @AuraEnabled public String rawAnswer;
        @AuraEnabled public String analysisMode;
        @AuraEnabled public String errorCode;
        @AuraEnabled public String errorMessage;
    }

    public class MetricStat {
        @AuraEnabled public Decimal mean;
        @AuraEnabled public Decimal min;
        @AuraEnabled public Decimal max;
        @AuraEnabled public String commentary;
    }

    public class Metrics {
        @AuraEnabled public String accountName;
        @AuraEnabled public Integer enrolled;
        @AuraEnabled public MetricStat dauWau;
        @AuraEnabled public MetricStat wauEnrolled;
        @AuraEnabled public MetricStat qpu;
    }

    @AuraEnabled
    public static InsightsJob submitJob(Id accountId) {
        if (accountId == null) {
            throw new AuraHandledException('accountId is required');
        }
        Account a = [SELECT Id, Name FROM Account WHERE Id = :accountId LIMIT 1];

        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:Rogo_Analytics/api/ask');
        req.setMethod('POST');
        req.setHeader('Authorization', 'Bearer ' + getBearerToken());
        req.setHeader('Content-Type', 'application/json');
        req.setBody(JSON.serialize(new Map<String, Object>{
            'question' => buildPrompt(a),
            'user_name' => UserInfo.getUserName()
        }));
        req.setTimeout(120000);

        HttpResponse res = new Http().send(req);
        Integer code = res.getStatusCode();
        if (code != 200 && code != 202) {
            throw new AuraHandledException('Rogo /api/ask failed: ' + code + ' ' + res.getBody());
        }
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        InsightsJob job = new InsightsJob();
        job.jobId = (String) body.get('job_id');
        job.status = (String) body.get('status');
        job.nextPollAfterMs = toInteger(body.get('next_poll_after_ms'));
        return job;
    }

    @AuraEnabled
    public static InsightsResult fetchJob(String jobId) {
        if (String.isBlank(jobId)) {
            throw new AuraHandledException('jobId is required');
        }
        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:Rogo_Analytics/api/jobs/' + EncodingUtil.urlEncode(jobId, 'UTF-8'));
        req.setMethod('GET');
        req.setHeader('Authorization', 'Bearer ' + getBearerToken());
        req.setTimeout(120000);

        HttpResponse res = new Http().send(req);
        Integer code = res.getStatusCode();
        if (code == 404) {
            // Rogo runs on Cloud Run with per-instance in-memory job storage. A
            // 404 here often means the poll landed on a different instance than
            // the one that accepted the job, rather than the job actually being
            // gone. Return a structured 'not_found' so the LWC can retry with
            // backoff before giving up.
            InsightsResult out = new InsightsResult();
            out.status = 'not_found';
            out.errorCode = 'job_not_found';
            out.errorMessage = 'Job not found on this Rogo instance';
            return out;
        }
        if (code != 200) {
            throw new AuraHandledException('Rogo /api/jobs failed: ' + code + ' ' + res.getBody());
        }
        return parseJobResponse(res.getBody());
    }

    @TestVisible
    private static InsightsResult parseJobResponse(String body) {
        Map<String, Object> root = (Map<String, Object>) JSON.deserializeUntyped(body);
        InsightsResult out = new InsightsResult();
        out.status = (String) root.get('status');
        out.progress = toDecimal(root.get('progress'));
        out.nextPollAfterMs = toInteger(root.get('next_poll_after_ms'));

        Map<String, Object> errInfo = (Map<String, Object>) root.get('error_info');
        if (errInfo != null) {
            out.errorCode = (String) errInfo.get('code');
            out.errorMessage = (String) errInfo.get('message');
        }

        Map<String, Object> result = (Map<String, Object>) root.get('result');
        if (result != null) {
            out.rawAnswer = (String) result.get('text');
            out.analysisMode = (String) result.get('analysis_mode');
            out.metrics = extractMetrics(out.rawAnswer);
        }
        return out;
    }

    @TestVisible
    private static Metrics extractMetrics(String answer) {
        if (String.isBlank(answer)) return null;
        Integer start = answer.indexOf('{');
        Integer fin = answer.lastIndexOf('}');
        if (start < 0 || fin <= start) return null;
        String jsonText = answer.substring(start, fin + 1);
        try {
            Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(jsonText);
            Metrics m = new Metrics();
            m.accountName  = (String) parsed.get('account');
            m.enrolled     = toInteger(parsed.get('enrolled'));
            m.dauWau       = parseStat(parsed.get('dau_wau'));
            m.wauEnrolled  = parseStat(parsed.get('wau_enrolled'));
            m.qpu          = parseStat(parsed.get('qpu'));
            return m;
        } catch (Exception e) {
            return null;
        }
    }

    @TestVisible
    private static MetricStat parseStat(Object raw) {
        if (raw == null) return null;
        // Tolerate the old flat shape (just a number) by treating it as the mean.
        if (!(raw instanceof Map<String, Object>)) {
            MetricStat fallback = new MetricStat();
            fallback.mean = toDecimal(raw);
            return fallback;
        }
        Map<String, Object> sm = (Map<String, Object>) raw;
        MetricStat s = new MetricStat();
        s.mean = toDecimal(sm.get('mean'));
        s.min = toDecimal(sm.get('min'));
        s.max = toDecimal(sm.get('max'));
        s.commentary = (String) sm.get('commentary');
        return s;
    }

    private static String buildPrompt(Account a) {
        return 'For the customer account named "' + a.Name + '" '
            + '(Salesforce account id: ' + a.Id + '), compute the following ROLLING daily '
            + 'metrics across the last 28 days using the analytics warehouse: '
            + '(1) DAU/WAU stickiness — for each day, that day\'s DAU divided by that day\'s WAU. '
            + '(2) WAU/Enrolled activation — for each day, that day\'s WAU divided by total enrolled users for the account. '
            + '(3) QPU engagement — for each day, count of queries in the prior 7 days divided by WAU on that day. '
            + 'For each metric, report the MEAN, MIN, and MAX across the 28-day window, '
            + 'plus a 1-2 sentence commentary on the trajectory '
            + '(e.g. "strong start with mid-period dip, recovering"). '
            + 'Also include the total enrolled user count for the account. '
            + 'Respond with ONLY a single JSON object, no prose, no markdown fences, no triple backticks. '
            + 'Schema: '
            + '{"account": "<account name>", "enrolled": <int>, '
            + '"dau_wau": {"mean": <0..1>, "min": <0..1>, "max": <0..1>, "commentary": "<text>"}, '
            + '"wau_enrolled": {"mean": <0..1>, "min": <0..1>, "max": <0..1>, "commentary": "<text>"}, '
            + '"qpu": {"mean": <number>, "min": <number>, "max": <number>, "commentary": "<text>"}}. '
            + 'If a metric is unavailable, set its numeric fields to null and put the reason in commentary.';
    }

    private static String getBearerToken() {
        if (bearerTokenOverride != null) return bearerTokenOverride;
        Rogo_Config__mdt cfg = Rogo_Config__mdt.getInstance('Default');
        if (cfg == null || String.isBlank(cfg.Bearer_Token__c)) {
            throw new AuraHandledException(
                'Rogo bearer token is not configured. Create a Rogo_Config__mdt record ' +
                'named "Default" with Bearer_Token__c populated.');
        }
        return cfg.Bearer_Token__c;
    }

    private static Integer toInteger(Object o) {
        if (o == null) return null;
        if (o instanceof Integer) return (Integer) o;
        if (o instanceof Decimal) return ((Decimal) o).intValue();
        if (o instanceof Double)  return ((Double) o).intValue();
        try { return Integer.valueOf(String.valueOf(o)); } catch (Exception e) { return null; }
    }

    private static Decimal toDecimal(Object o) {
        if (o == null) return null;
        if (o instanceof Decimal) return (Decimal) o;
        if (o instanceof Integer) return Decimal.valueOf((Integer) o);
        if (o instanceof Double)  return Decimal.valueOf((Double) o);
        try { return Decimal.valueOf(String.valueOf(o)); } catch (Exception e) { return null; }
    }
}
