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
        @AuraEnabled public String   accountStatus;
        @AuraEnabled public Decimal  arr;
        @AuraEnabled public Decimal  estimatedTam;
        @AuraEnabled public String   website;
        @AuraEnabled public Date     lastActivityDate;
        @AuraEnabled public String   lastActivitySubject;
        @AuraEnabled public DateTime lastGongCallDate;
        @AuraEnabled public Integer  contactCount;
        @AuraEnabled public Boolean  hasGtmaAssociate; // Account.GTM_Associate__c != null
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
        @AuraEnabled public List<Weekly_Commit__c> lastWeekCommits;
        @AuraEnabled public ScorecardData          lastWeekScorecard;
        @AuraEnabled public List<String>           riskReasons;
        @AuraEnabled public Boolean                hasRisk;
        @AuraEnabled public Integer                inFlightOppCount;
        @AuraEnabled public Integer                thisWeekTotal;
        @AuraEnabled public Integer                thisWeekCompleted;
        @AuraEnabled public Decimal                pipelineTarget;
        @AuraEnabled public Decimal                pipelineActual;
        @AuraEnabled public Integer                weeksRemaining;
        @AuraEnabled public String                 quarter;
        @AuraEnabled public Integer                lwOppsCreated;
        @AuraEnabled public Integer                qtdOppsCreated;
        @AuraEnabled public Integer                lwOppsToDiscovery;
        @AuraEnabled public Integer                qtdOppsToDiscovery;
    }

    public class ManagerSummary {
        @AuraEnabled public String           managerId;
        @AuraEnabled public String           managerName;
        @AuraEnabled public List<RepSummary> reps;
        @AuraEnabled public Integer          totalReps;
        @AuraEnabled public Integer          repsAtRisk;
        @AuraEnabled public Integer          thisWeekTotal;
        @AuraEnabled public Integer          thisWeekCompleted;
        @AuraEnabled public Integer          lwTotal;
        @AuraEnabled public Integer          lwCompleted;
        @AuraEnabled public Decimal          pipelineActual;
        @AuraEnabled public Decimal          pipelineTarget;
        @AuraEnabled public Integer          lwOppsCreated;
        @AuraEnabled public Integer          qtdOppsCreated;
        @AuraEnabled public Integer          lwOppsToDiscovery;
        @AuraEnabled public Integer          qtdOppsToDiscovery;
        @AuraEnabled public Integer          inFlightTotal;
        @AuraEnabled public Boolean          hasRisk;
    }

    public class VPDashboardData {
        @AuraEnabled public Boolean              isVP;
        @AuraEnabled public List<ManagerSummary> managers;
        @AuraEnabled public List<RepSummary>     reps;
        @AuraEnabled public TeamSummary          teamSummary;
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