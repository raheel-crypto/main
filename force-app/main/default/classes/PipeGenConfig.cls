// Centralizes all Custom Metadata lookups so selectors, services, and the controller
// can share config without creating circular dependencies.
public with sharing class PipeGenConfig {

    // Closed Lost is a filter target only, not a configured pipeline stage.
    public static final String CLOSED_LOST = 'Closed Lost';

    // ─── Caches ──────────────────────────────────────────────────────────────────

    @TestVisible
    public static Map<String, PipeGen_Stage__mdt> stageConfigCache;

    @TestVisible
    public static Map<String, PipeGen_Commit_Type__mdt> commitTypeConfigCache;

    // ─── CMT Loaders ─────────────────────────────────────────────────────────────

    public static Map<String, PipeGen_Stage__mdt> getStageConfig() {
        if (stageConfigCache == null) {
            stageConfigCache = new Map<String, PipeGen_Stage__mdt>();
            for (PipeGen_Stage__mdt s : [
                SELECT Stage_Name__c, Stage_Order__c, Is_In_Flight__c, Is_Pipeline_Stage__c,
                       Is_Advanced_Stage__c, Is_Closed_Won__c, Stale_Threshold_Days__c, Card_Color_Class__c
                FROM PipeGen_Stage__mdt
            ]) {
                stageConfigCache.put(s.Stage_Name__c, s);
            }
        }
        return stageConfigCache;
    }

    public static Map<String, PipeGen_Commit_Type__mdt> getCommitTypeConfig() {
        if (commitTypeConfigCache == null) {
            commitTypeConfigCache = new Map<String, PipeGen_Commit_Type__mdt>();
            for (PipeGen_Commit_Type__mdt c : [
                SELECT Commit_Type_Name__c, Motion__c, Display_Label__c,
                       Verification_Method__c, Meeting_Type_Names__c, Sort_Order__c
                FROM PipeGen_Commit_Type__mdt
            ]) {
                commitTypeConfigCache.put(c.Commit_Type_Name__c, c);
            }
        }
        return commitTypeConfigCache;
    }

    // ─── Stage Helpers ────────────────────────────────────────────────────────────

    public static Set<String> getInFlightStageNames() {
        Set<String> result = new Set<String>();
        for (PipeGen_Stage__mdt s : getStageConfig().values()) {
            if (s.Is_In_Flight__c == true) result.add(s.Stage_Name__c);
        }
        return result;
    }

    public static Set<String> getPipelineStageNames() {
        Set<String> result = new Set<String>();
        for (PipeGen_Stage__mdt s : getStageConfig().values()) {
            if (s.Is_Pipeline_Stage__c == true) result.add(s.Stage_Name__c);
        }
        return result;
    }

    public static Set<String> getAdvancedStageNames() {
        Set<String> result = new Set<String>();
        for (PipeGen_Stage__mdt s : getStageConfig().values()) {
            if (s.Is_Advanced_Stage__c == true) result.add(s.Stage_Name__c);
        }
        return result;
    }

    public static List<String> getStageOrderList() {
        Map<Decimal, PipeGen_Stage__mdt> byOrder = new Map<Decimal, PipeGen_Stage__mdt>();
        for (PipeGen_Stage__mdt s : getStageConfig().values()) {
            if (s.Stage_Order__c != null) byOrder.put(s.Stage_Order__c, s);
        }
        List<Decimal> orders = new List<Decimal>(byOrder.keySet());
        orders.sort();
        List<String> result = new List<String>();
        for (Decimal o : orders) result.add(byOrder.get(o).Stage_Name__c);
        return result;
    }

    public static Integer getStaleThreshold(String stageName) {
        PipeGen_Stage__mdt s = getStageConfig().get(stageName);
        if (s == null || s.Stale_Threshold_Days__c == null) return 21;
        return Integer.valueOf(s.Stale_Threshold_Days__c);
    }

    public static Boolean isClosedWon(String stageName) {
        PipeGen_Stage__mdt s = getStageConfig().get(stageName);
        return s != null && s.Is_Closed_Won__c == true;
    }

    public static Boolean isPipelineStage(String stageName) {
        PipeGen_Stage__mdt s = getStageConfig().get(stageName);
        return s != null && s.Is_Pipeline_Stage__c == true;
    }

    public static Boolean isAdvancedStage(String stageName) {
        PipeGen_Stage__mdt s = getStageConfig().get(stageName);
        return s != null && s.Is_Advanced_Stage__c == true;
    }

    // Early stage = in-flight but not yet advanced (Demo, Discovery)
    public static Boolean isEarlyStage(String stageName) {
        PipeGen_Stage__mdt s = getStageConfig().get(stageName);
        return s != null && s.Is_In_Flight__c == true && s.Is_Advanced_Stage__c != true;
    }

    // ─── Commit Type Helpers ──────────────────────────────────────────────────────

    public static Boolean isCommitTypeManual(String commitTypeName) {
        PipeGen_Commit_Type__mdt c = getCommitTypeConfig().get(commitTypeName);
        return c != null && 'Manual'.equals(c.Verification_Method__c);
    }

    public static Boolean isCommitTypeTaskBased(String commitTypeName) {
        PipeGen_Commit_Type__mdt c = getCommitTypeConfig().get(commitTypeName);
        return c != null && 'Task_With_DM_Contact'.equals(c.Verification_Method__c);
    }

    // Returns null when any meeting type qualifies (e.g. Multi-Thread)
    public static Set<String> getMeetingTypesForCommit(String commitTypeName) {
        PipeGen_Commit_Type__mdt c = getCommitTypeConfig().get(commitTypeName);
        if (c == null || !'Event_Meeting_Type'.equals(c.Verification_Method__c)) return null;
        if (String.isBlank(c.Meeting_Type_Names__c)) return null;
        Set<String> result = new Set<String>();
        for (String t : c.Meeting_Type_Names__c.split(';')) {
            String trimmed = t.trim();
            if (String.isNotBlank(trimmed)) result.add(trimmed);
        }
        return result;
    }

    // ─── Week Utility ─────────────────────────────────────────────────────────────

    // Returns the Monday of the week containing d (Jan 1 1900 was a Monday)
    public static Date getWeekStart(Date d) {
        Date monday1900 = Date.newInstance(1900, 1, 1);
        Integer daysSince = monday1900.daysBetween(d);
        Integer dow = Math.mod(daysSince, 7);
        return d.addDays(-dow);
    }
}
