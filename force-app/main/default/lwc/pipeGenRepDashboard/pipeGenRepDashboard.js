import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getRepDashboardData      from '@salesforce/apex/PipeGenController.getRepDashboardData';
import saveCommit               from '@salesforce/apex/PipeGenController.saveCommit';
import deleteCommit             from '@salesforce/apex/PipeGenController.deleteCommit';
import getAccountsForSelection  from '@salesforce/apex/PipeGenController.getAccountsForSelection';
import updateTargetAccounts     from '@salesforce/apex/PipeGenController.updateTargetAccounts';
import markCommitComplete       from '@salesforce/apex/PipeGenController.markCommitComplete';

const CURRENCY  = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD', maximumFractionDigits: 0 });
const SHORT_DATE = new Intl.DateTimeFormat('en-US', { month: 'short', day: 'numeric' });

const EMPTY_COMMIT = () => ({
    motionType:     'Net New',
    commitType:     '',
    description:    '',
    accountId:      null,
    accountName:    '',
    oppId:          null,
    committedCount: 1
});

export default class PipeGenRepDashboard extends LightningElement {

    // ─── Dashboard state ──────────────────────────────────────────────────────
    @track data                 = null;
    @track isLoading            = true;
    @track errorMessage         = null;
    @track showCommitForm       = false;
    @track isSaving             = false;
    @track accountSearchResults = [];
    @track newCommit            = EMPTY_COMMIT();

    // ─── Account card tab state ───────────────────────────────────────────────
    @track accountCards         = [];
    @track accountCardsLoaded   = false;
    @track isLoadingCards       = false;
    @track isSavingTargets      = false;
    @track cardSearchTerm       = '';

    // ─── Lifecycle ────────────────────────────────────────────────────────────

    connectedCallback() {
        this.loadData();
    }

    // ─── Data Loading ─────────────────────────────────────────────────────────

    async loadData() {
        this.isLoading    = true;
        this.errorMessage = null;
        try {
            const raw = await getRepDashboardData();
            this.data = this.processData(raw);
        } catch (e) {
            this.errorMessage = e.body?.message || 'Failed to load dashboard data.';
        } finally {
            this.isLoading = false;
        }
    }

    processData(raw) {
        const today = new Date();
        return {
            ...raw,
            targetAccounts:  (raw.targetAccounts  || []).map(a => this.enrichAccount(a, today)),
            inFlightOpps:    (raw.inFlightOpps    || []).map(o => this.enrichOpp(o)),
            thisWeekCommits: (raw.thisWeekCommits || []).map(c => this.enrichCommit(c))
        };
    }

    enrichCommit(c) {
        const actual    = c.Actual_Count__c    || 0;
        const committed = c.Committed_Count__c || 1;
        const status    = c.Completion_Status__c || 'Not Started';
        const isMEDDPICC = c.Commit_Type__c === 'MEDDPICC Complete';
        return {
            ...c,
            isMEDDPICC,
            isCompleted:    status === 'Completed',
            progressLabel:  `${actual} / ${committed}`,
            statusDotClass: status === 'Completed' ? 'status-dot status-dot--complete'
                          : status === 'Partial'   ? 'status-dot status-dot--partial'
                          :                          'status-dot status-dot--pending',
            commitCardClass: status === 'Completed' ? 'commit-card commit-card--complete'
                           : status === 'Partial'   ? 'commit-card commit-card--partial'
                           :                          'commit-card commit-card--pending',
            showMarkDone:   isMEDDPICC && status !== 'Completed'
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

    enrichOpp(o) {
        return {
            ...o,
            sfUrl:                    `/lightning/r/Opportunity/${o.id}/view`,
            amountFormatted:           CURRENCY.format(o.amount || 0),
            lastActivityDateFormatted: o.lastActivityDate ? this.fmtDate(o.lastActivityDate) : '—',
            lastGongCallDateFormatted: o.lastGongCallDate ? this.fmtDate(o.lastGongCallDate) : '—',
            stageBadgeClass:  o.stageName === 'Stage 2' ? 'stage-badge stage-badge--s2' : 'stage-badge stage-badge--s1',
            rowClass:         o.isStale ? 'slds-hint-parent stale-row' : 'slds-hint-parent',
            daysClass:        o.isStale ? 'stale-text bold-cell' : 'bold-cell',
            contactClass:     (o.contactRoleCount || 0) < 2 ? 'stale-text' : 'healthy-text',
            staleLabel:       `>${o.staleThreshold}d`
        };
    }

    // ─── Computed — visibility ────────────────────────────────────────────────

    get isReady()              { return !this.isLoading && !this.errorMessage && !!this.data; }
    get hasError()             { return !!this.errorMessage; }
    get hasAccounts()          { return (this.data?.targetAccounts?.length  || 0) > 0; }
    get hasInFlightOpps()      { return (this.data?.inFlightOpps?.length    || 0) > 0; }
    get hasNetNewCommits()     { return this.netNewCommits.length > 0; }
    get hasProgressionCommits(){ return this.progressionCommits.length > 0; }
    get hasAccountResults()    { return this.accountSearchResults.length > 0; }
    get isNetNew()             { return this.newCommit.motionType === 'Net New'; }
    get isProgression()        { return this.newCommit.motionType === 'Progression'; }

    get staleOppCount() {
        return (this.data?.inFlightOpps || []).filter(o => o.isStale).length;
    }
    get mandatoryProgressionWarning() {
        return this.staleOppCount > 0 && this.progressionCommits.length === 0;
    }

    // ─── Computed — labels ────────────────────────────────────────────────────

    get accountCountLabel()   { return `${this.data?.targetAccounts?.length || 0} accounts`; }
    get inFlightCountLabel()  { return `${this.data?.inFlightOpps?.length   || 0} opps`; }

    // ─── Computed — quarterly target ─────────────────────────────────────────

    get qt()                     { return this.data?.quarterlyTarget || {}; }
    get netNewPercent()          { return pct(this.qt.netNewActual,      this.qt.netNewTarget); }
    get progPercent()            { return pct(this.qt.progressionActual, this.qt.progressionTarget); }
    get blendedPercent()         { return pct((this.qt.netNewActual||0) + (this.qt.progressionActual||0), this.qt.totalTarget); }
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

    // ─── Computed — commits ───────────────────────────────────────────────────

    get netNewCommits() {
        return (this.data?.thisWeekCommits || []).filter(c => c.Motion_Type__c === 'Net New');
    }
    get progressionCommits() {
        return (this.data?.thisWeekCommits || []).filter(c => c.Motion_Type__c === 'Progression');
    }

    // ─── Computed — scorecard ─────────────────────────────────────────────────

    get scorecard() {
        const sc = this.data?.lastWeekScorecard || {};
        return {
            ...sc,
            nnDollarFormatted:           CURRENCY.format(sc.nnDollarGenerated || 0),
            progConversionRateFormatted: `${Math.round(sc.progConversionRate || 0)}%`
        };
    }

    // ─── Computed — commit form options ──────────────────────────────────────

    get motionOptions() {
        return [
            { label: 'Net New',     value: 'Net New' },
            { label: 'Progression', value: 'Progression' }
        ];
    }

    get commitTypeOptions() {
        if (this.isNetNew) {
            return [
                { label: 'First Meeting Booked',   value: 'First Meeting Booked' },
                { label: 'Multi-Thread Intro',      value: 'Multi-Thread Intro' },
                { label: 'Champion-Led Referral',   value: 'Champion-Led Referral' },
                { label: 'Exec Outreach Sequence',  value: 'Exec Outreach Sequence' },
                { label: 'Inbound Converted',       value: 'Inbound Converted' }
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

    get inFlightOppOptions() {
        return (this.data?.inFlightOpps || []).map(o => ({
            label: `${o.name} — ${o.accountName} (${o.stageName}, ${o.daysInStage}d)`,
            value: o.id
        }));
    }

    // ─── Computed — account cards ────────────────────────────────────────────

    get filteredCards() {
        const term = this.cardSearchTerm.toLowerCase();
        return term.length < 2
            ? this.accountCards
            : this.accountCards.filter(c => c.name.toLowerCase().includes(term) || (c.industry || '').toLowerCase().includes(term));
    }

    get targetedCards() {
        return this.filteredCards.filter(c => c.effectiveTargeted).map(c => this.applyCardClass(c));
    }

    get untargetedCards() {
        return this.filteredCards.filter(c => !c.effectiveTargeted).map(c => this.applyCardClass(c));
    }

    get pendingChanges() {
        return this.accountCards.filter(c => c.effectiveTargeted !== c.isTargeted);
    }

    get hasPendingChanges()  { return this.pendingChanges.length > 0; }
    get pendingCount()       { return this.pendingChanges.length; }
    get pendingLabel()       { return `Save ${this.pendingCount} change${this.pendingCount === 1 ? '' : 's'}`; }
    get pendingCountLabel()  { return `${this.pendingCount} unsaved change${this.pendingCount === 1 ? '' : 's'}`; }
    get targetedCardCount()  { return this.accountCards.filter(c => c.effectiveTargeted).length; }
    get totalCardCount()     { return this.accountCards.length; }

    applyCardClass(c) {
        const isPending = c.effectiveTargeted !== c.isTargeted;
        let cls = 'acct-card';
        if (c.effectiveTargeted) cls += ' acct-card--targeted';
        if (isPending && c.effectiveTargeted)  cls += ' acct-card--pending-add';
        if (isPending && !c.effectiveTargeted) cls += ' acct-card--pending-remove';
        return { ...c, cardClass: cls, isPending };
    }

    // ─── Commit Form Handlers ─────────────────────────────────────────────────

    openCommitForm()  { this.showCommitForm = true; this.newCommit = EMPTY_COMMIT(); this.accountSearchResults = []; }
    closeCommitForm() { this.showCommitForm = false; }

    handleMotionChange(e)      { this.newCommit = { ...EMPTY_COMMIT(), motionType: e.detail.value }; this.accountSearchResults = []; }
    handleCommitTypeChange(e)  { this.newCommit = { ...this.newCommit, commitType:    e.detail.value }; }
    handleDescriptionChange(e) { this.newCommit = { ...this.newCommit, description:   e.detail.value }; }
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
            Target_Account__c:     this.newCommit.accountId || null,
            Target_Opportunity__c: this.newCommit.oppId     || null
        };

        try {
            const saved = await saveCommit({ commitRecord: record });
            this.data = { ...this.data, thisWeekCommits: [...(this.data.thisWeekCommits || []), this.enrichCommit(saved)] };
            this.closeCommitForm();
            this.toast('Commit Saved', 'Your weekly commit has been recorded.', 'success');
        } catch (e) {
            this.toast('Save Failed', e.body?.message || 'Could not save commit.', 'error');
        } finally {
            this.isSaving = false;
        }
    }

    async handleDeleteCommit(e) {
        const id = e.currentTarget.dataset.id;
        try {
            await deleteCommit({ commitId: id });
            this.data = { ...this.data, thisWeekCommits: (this.data.thisWeekCommits || []).filter(c => c.Id !== id) };
            this.toast('Removed', 'Commit deleted.', 'success');
        } catch (err) {
            this.toast('Error', 'Could not delete commit.', 'error');
        }
    }

    async handleMarkMEDDPICCComplete(e) {
        const id = e.currentTarget.dataset.id;
        try {
            await markCommitComplete({ commitId: id });
            await this.loadData();
        } catch (err) {
            this.toast('Error', 'Could not mark commit complete.', 'error');
        }
    }

    // ─── Account Cards Handlers ───────────────────────────────────────────────

    async handleAccountsTabActive() {
        if (this.accountCardsLoaded) return;
        this.isLoadingCards = true;
        try {
            const raw = await getAccountsForSelection();
            this.accountCards = raw.map(c => ({ ...c, effectiveTargeted: c.isTargeted }));
            this.accountCardsLoaded = true;
        } catch (e) {
            this.toast('Error', 'Could not load accounts.', 'error');
        } finally {
            this.isLoadingCards = false;
        }
    }

    handleCardToggle(e) {
        const id = e.currentTarget.dataset.id;
        this.accountCards = this.accountCards.map(c =>
            c.id === id ? { ...c, effectiveTargeted: !c.effectiveTargeted } : c
        );
    }

    handleCardSearch(e) {
        this.cardSearchTerm = e.detail.value || '';
    }

    cancelTargetChanges() {
        this.accountCards = this.accountCards.map(c => ({ ...c, effectiveTargeted: c.isTargeted }));
    }

    async saveTargetAccounts() {
        const changes    = this.accountCards.filter(c => c.effectiveTargeted !== c.isTargeted);
        const toTarget   = changes.filter(c =>  c.effectiveTargeted).map(c => c.id);
        const toUntarget = changes.filter(c => !c.effectiveTargeted).map(c => c.id);
        const count      = changes.length;

        this.isSavingTargets = true;
        try {
            await updateTargetAccounts({ toTarget, toUntarget });
            this.accountCards = this.accountCards.map(c => ({ ...c, isTargeted: c.effectiveTargeted }));
            this.toast('Saved', `${count} account${count === 1 ? '' : 's'} updated.`, 'success');
            this.loadData(); // refresh dashboard target account list
        } catch (e) {
            this.toast('Error', e.body?.message || 'Could not update accounts.', 'error');
        } finally {
            this.isSavingTargets = false;
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

function pct(actual, target) {
    if (!target || target <= 0) return 0;
    return Math.min(100, Math.round((actual / target) * 100));
}
