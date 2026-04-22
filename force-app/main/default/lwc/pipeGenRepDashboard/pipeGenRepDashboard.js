import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getRepDashboardData from '@salesforce/apex/PipeGenController.getRepDashboardData';
import saveCommit        from '@salesforce/apex/PipeGenController.saveCommit';
import deleteCommit      from '@salesforce/apex/PipeGenController.deleteCommit';

const CURRENCY = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD', maximumFractionDigits: 0 });
const SHORT_DATE = new Intl.DateTimeFormat('en-US', { month: 'short', day: 'numeric' });
const STALE_DAYS = 21;

const EMPTY_COMMIT = () => ({
    motionType:   'Net New',
    commitType:   '',
    description:  '',
    accountId:    null,
    accountName:  '',
    oppId:        null,
    committedCount: 1
});

export default class PipeGenRepDashboard extends LightningElement {

    @track data                 = null;
    @track isLoading            = true;
    @track errorMessage         = null;
    @track showCommitForm       = false;
    @track isSaving             = false;
    @track accountSearchResults = [];
    @track newCommit            = EMPTY_COMMIT();

    // ─── Lifecycle ────────────────────────────────────────────────────────────

    connectedCallback() {
        this.loadData();
    }

    // ─── Data Loading ─────────────────────────────────────────────────────────

    async loadData() {
        this.isLoading    = true;
        this.errorMessage = null;
        try {
            const raw  = await getRepDashboardData();
            this.data  = this.processData(raw);
        } catch (e) {
            this.errorMessage = e.body?.message || 'Failed to load dashboard data. Check the browser console for details.';
        } finally {
            this.isLoading = false;
        }
    }

    processData(raw) {
        const today = new Date();
        return {
            ...raw,
            targetAccounts: (raw.targetAccounts || []).map(a => this.enrichAccount(a, today)),
            stage1Opps:     (raw.stage1Opps     || []).map(o => this.enrichOpp(o, today))
        };
    }

    enrichAccount(a, today) {
        const daysSinceActivity = a.lastActivityDate ? this.daysSince(a.lastActivityDate, today) : 999;
        const daysSinceGong     = a.lastGongCallDate ? this.daysSince(a.lastGongCallDate, today) : 999;
        return {
            ...a,
            sfUrl:                     `/lightning/r/Account/${a.id}/view`,
            lastActivityDateFormatted:  a.lastActivityDate ? this.fmtDate(a.lastActivityDate) : '—',
            lastGongCallDateFormatted:  a.lastGongCallDate ? this.fmtDate(a.lastGongCallDate) : '—',
            activityClass: daysSinceActivity > 30 ? 'stale-text' : 'slds-text-body_small',
            gongClass:     daysSinceGong     > 30 ? 'stale-text' : 'slds-text-body_small',
            threadClass:   (a.contactCount || 0) >= 3
                ? 'healthy-text'
                : ((a.contactCount || 0) === 0 ? 'stale-text' : 'slds-text-body_small')
        };
    }

    enrichOpp(o, today) {
        return {
            ...o,
            sfUrl:                    `/lightning/r/Opportunity/${o.id}/view`,
            amountFormatted:           CURRENCY.format(o.amount || 0),
            lastActivityDateFormatted: o.lastActivityDate ? this.fmtDate(o.lastActivityDate) : '—',
            lastGongCallDateFormatted: o.lastGongCallDate ? this.fmtDate(o.lastGongCallDate) : '—',
            rowClass:     o.isStale ? 'slds-hint-parent stale-row' : 'slds-hint-parent',
            daysClass:    o.isStale ? 'stale-text bold-cell' : 'bold-cell',
            contactClass: (o.contactRoleCount || 0) < 2 ? 'stale-text' : 'healthy-text'
        };
    }

    // ─── Computed Properties — visibility ────────────────────────────────────

    get isReady()             { return !this.isLoading && !this.errorMessage && !!this.data; }
    get hasError()            { return !!this.errorMessage; }
    get hasAccounts()         { return (this.data?.targetAccounts?.length || 0) > 0; }
    get hasStage1Opps()       { return (this.data?.stage1Opps?.length     || 0) > 0; }
    get hasNetNewCommits()    { return this.netNewCommits.length > 0; }
    get hasProgressionCommits(){ return this.progressionCommits.length > 0; }
    get hasAccountResults()   { return this.accountSearchResults.length > 0; }
    get isNetNew()            { return this.newCommit.motionType === 'Net New'; }
    get isProgression()       { return this.newCommit.motionType === 'Progression'; }

    get staleOppCount()  { return (this.data?.stage1Opps || []).filter(o => o.isStale).length; }
    get staleThreshold() { return STALE_DAYS; }

    get mandatoryProgressionWarning() {
        return this.staleOppCount > 0 && this.progressionCommits.length === 0;
    }

    // ─── Computed Properties — labels ────────────────────────────────────────

    get accountCountLabel() { return `${this.data?.targetAccounts?.length || 0} accounts`; }
    get stage1CountLabel()  { return `${this.data?.stage1Opps?.length     || 0} opps`; }

    // ─── Computed Properties — quarterly target ───────────────────────────────

    get qt()                  { return this.data?.quarterlyTarget || {}; }
    get netNewPercent()       { return pct(this.qt.netNewActual,      this.qt.netNewTarget); }
    get progPercent()         { return pct(this.qt.progressionActual, this.qt.progressionTarget); }
    get blendedPercent()      { return pct((this.qt.netNewActual||0) + (this.qt.progressionActual||0), this.qt.totalTarget); }
    get netNewActualFormatted()  { return CURRENCY.format(this.qt.netNewActual      || 0); }
    get netNewTargetFormatted()  { return CURRENCY.format(this.qt.netNewTarget      || 0); }
    get progActualFormatted()    { return CURRENCY.format(this.qt.progressionActual || 0); }
    get progTargetFormatted()    { return CURRENCY.format(this.qt.progressionTarget || 0); }
    get netNewGapFormatted()     { return CURRENCY.format(Math.max(0, (this.qt.netNewTarget||0)      - (this.qt.netNewActual||0))); }
    get progGapFormatted()       { return CURRENCY.format(Math.max(0, (this.qt.progressionTarget||0) - (this.qt.progressionActual||0))); }
    get totalGapFormatted() {
        const gap = (this.qt.totalTarget||0) - (this.qt.netNewActual||0) - (this.qt.progressionActual||0);
        return CURRENCY.format(Math.max(0, gap));
    }

    // ─── Computed Properties — commits ───────────────────────────────────────

    get netNewCommits() {
        return (this.data?.thisWeekCommits || []).filter(c => c.Motion_Type__c === 'Net New');
    }
    get progressionCommits() {
        return (this.data?.thisWeekCommits || []).filter(c => c.Motion_Type__c === 'Progression');
    }

    // ─── Computed Properties — scorecard ─────────────────────────────────────

    get scorecard() {
        const sc = this.data?.lastWeekScorecard || {};
        return {
            ...sc,
            nnDollarFormatted:          CURRENCY.format(sc.nnDollarGenerated || 0),
            progConversionRateFormatted: `${Math.round(sc.progConversionRate || 0)}%`
        };
    }

    // ─── Computed Properties — form options ──────────────────────────────────

    get motionOptions() {
        return [
            { label: 'Net New',     value: 'Net New' },
            { label: 'Progression', value: 'Progression' }
        ];
    }

    get commitTypeOptions() {
        if (this.isNetNew) {
            return [
                { label: 'First Meeting Booked',    value: 'First Meeting Booked' },
                { label: 'Multi-Thread Intro',       value: 'Multi-Thread Intro' },
                { label: 'Champion-Led Referral',    value: 'Champion-Led Referral' },
                { label: 'Exec Outreach Sequence',   value: 'Exec Outreach Sequence' },
                { label: 'Inbound Converted',        value: 'Inbound Converted' }
            ];
        }
        return [
            { label: 'Discovery Call (Economic Buyer)', value: 'Discovery Call - Economic Buyer' },
            { label: 'Multi-Thread (3+ Contacts)',      value: 'Multi-Thread' },
            { label: 'Technical Validation',            value: 'Technical Validation' },
            { label: 'Exec Alignment',                  value: 'Exec Alignment' },
            { label: 'MEDDPICC Fields Complete',        value: 'MEDDPICC Complete' }
        ];
    }

    get stage1OppOptions() {
        return (this.data?.stage1Opps || []).map(o => ({
            label: `${o.name} — ${o.accountName} (${o.daysInStage}d in S1)`,
            value: o.id
        }));
    }

    // ─── Commit Form Handlers ─────────────────────────────────────────────────

    openCommitForm()  { this.showCommitForm = true;  this.newCommit = EMPTY_COMMIT(); this.accountSearchResults = []; }
    closeCommitForm() { this.showCommitForm = false; }

    handleMotionChange(e)      { this.newCommit = { ...EMPTY_COMMIT(), motionType: e.detail.value }; this.accountSearchResults = []; }
    handleCommitTypeChange(e)  { this.newCommit = { ...this.newCommit, commitType:   e.detail.value }; }
    handleDescriptionChange(e) { this.newCommit = { ...this.newCommit, description:  e.detail.value }; }
    handleCountChange(e)       { this.newCommit = { ...this.newCommit, committedCount: parseInt(e.detail.value, 10) || 1 }; }
    handleOppChange(e)         { this.newCommit = { ...this.newCommit, oppId: e.detail.value }; }

    handleAccountSearch(e) {
        const term = e.detail.value || '';
        this.newCommit = { ...this.newCommit, accountName: term };
        this.accountSearchResults = term.length >= 2
            ? (this.data?.targetAccounts || [])
                .filter(a => a.name.toLowerCase().includes(term.toLowerCase()))
                .slice(0, 6)
                .map(a => ({ id: a.id, name: a.name }))
            : [];
    }

    selectAccount(e) {
        const id   = e.currentTarget.dataset.id;
        const name = e.currentTarget.dataset.name;
        this.newCommit = { ...this.newCommit, accountId: id, accountName: name };
        this.accountSearchResults = [];
    }

    async saveNewCommit() {
        if (!this.newCommit.commitType || !this.newCommit.description) {
            this.toast('Missing Fields', 'Commit Type and Description are required.', 'error');
            return;
        }
        if (this.isProgression && !this.newCommit.oppId) {
            this.toast('Missing Opportunity', 'Select a target opp for progression commits.', 'error');
            return;
        }

        this.isSaving = true;
        const record = {
            Motion_Type__c:        this.newCommit.motionType,
            Commit_Type__c:        this.newCommit.commitType,
            Commit_Description__c: this.newCommit.description,
            Committed_Count__c:    this.newCommit.committedCount,
            Target_Account__c:     this.newCommit.accountId   || null,
            Target_Opportunity__c: this.newCommit.oppId       || null
        };

        try {
            const saved = await saveCommit({ commitRecord: record });
            this.data = {
                ...this.data,
                thisWeekCommits: [...(this.data.thisWeekCommits || []), saved]
            };
            this.closeCommitForm();
            this.toast('Commit Saved', 'Your weekly commit has been recorded.', 'success');
        } catch (e) {
            this.toast('Save Failed', e.body?.message || 'Could not save commit. Check field permissions.', 'error');
        } finally {
            this.isSaving = false;
        }
    }

    async handleDeleteCommit(e) {
        const id = e.currentTarget.dataset.id;
        try {
            await deleteCommit({ commitId: id });
            this.data = {
                ...this.data,
                thisWeekCommits: (this.data.thisWeekCommits || []).filter(c => c.Id !== id)
            };
            this.toast('Removed', 'Commit deleted.', 'success');
        } catch (err) {
            this.toast('Error', 'Could not delete commit.', 'error');
        }
    }

    // ─── Utilities ────────────────────────────────────────────────────────────

    daysSince(dateStr, today) {
        return Math.floor((today - new Date(dateStr)) / 86400000);
    }

    fmtDate(dateStr) {
        if (!dateStr) return '—';
        return SHORT_DATE.format(new Date(dateStr));
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}

// Module-level helper — avoids repeated inline math
function pct(actual, target) {
    if (!target || target <= 0) return 0;
    return Math.min(100, Math.round((actual / target) * 100));
}
