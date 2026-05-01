import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getRepDashboardData           from '@salesforce/apex/PipeGenController.getRepDashboardData';
import saveCommit                    from '@salesforce/apex/PipeGenController.saveCommit';
import deleteCommit                  from '@salesforce/apex/PipeGenController.deleteCommit';
import getAccountsForSelection       from '@salesforce/apex/PipeGenController.getAccountsForSelection';
import updateTargetAccounts          from '@salesforce/apex/PipeGenController.updateTargetAccounts';
import markCommitComplete            from '@salesforce/apex/PipeGenController.markCommitComplete';
import carryForwardIncompleteCommits from '@salesforce/apex/PipeGenController.carryForwardIncompleteCommits';

const CURRENCY   = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD', maximumFractionDigits: 0 });
const SHORT_DATE = new Intl.DateTimeFormat('en-US', { month: 'short', day: 'numeric' });

const SEGMENT_ORDER = ['Expansion', 'Early Stage', 'Uncracked', 'Recent Closed Lost', 'No Opportunities', 'Other'];

const AVATAR_COLORS = ['#3b82f6','#8b5cf6','#ec4899','#f59e0b','#10b981','#06b6d4','#ef4444','#6366f1'];

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
    @track isCarryingForward    = false;
    @track accountSearchResults = [];
    @track newCommit            = EMPTY_COMMIT();

    // ─── Account card tab state ───────────────────────────────────────────────
    @track accountCards         = [];
    @track accountCardsLoaded   = false;
    @track isLoadingCards       = false;
    @track isSavingTargets      = false;
    @track cardSearchTerm       = '';
    @track accountSortBy        = 'name';

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
        const actual     = c.Actual_Count__c    || 0;
        const committed  = c.Committed_Count__c || 1;
        const status     = c.Completion_Status__c || 'Not Started';
        const isMEDDPICC = c.Commit_Type__c === 'MEDDPICC Complete';
        const isNN       = c.Motion_Type__c === 'Net New';
        const motionSuffix = isNN ? 'nn' : 'prog';
        const statusSuffix = status === 'Completed' ? 'complete'
                           : status === 'Partial'   ? 'partial'
                           :                          'pending';
        // Explicitly read relationship objects before spread — LWC SObject proxies
        // do not always enumerate relationship fields when spread with {...c}
        const acctRel = c.Target_Account__r     || null;
        const oppRel  = c.Target_Opportunity__r || null;
        const refName = (acctRel && acctRel.Name) || (oppRel && oppRel.Name) || '';
        return {
            ...c,
            Target_Account__r:     acctRel,
            Target_Opportunity__r: oppRel,
            isMEDDPICC,
            isCompleted:     status === 'Completed',
            progressLabel:   `${actual} / ${committed}`,
            refName,
            statusDotClass:  status === 'Completed' ? 'status-dot status-dot--complete'
                           : status === 'Partial'   ? 'status-dot status-dot--partial'
                           :                          'status-dot status-dot--pending',
            commitCardClass: `commit-card commit-card--${motionSuffix} commit-card--${statusSuffix}`,
            showMarkDone:    isMEDDPICC && status !== 'Completed'
        };
    }

    enrichAccount(a, today) {
        const daysSinceActivity = a.lastActivityDate ? this.daysSince(a.lastActivityDate, today) : 999;
        const daysSinceGong     = a.lastGongCallDate ? this.daysSince(a.lastGongCallDate, today) : 999;
        const initial  = (a.name || '?').charAt(0).toUpperCase();
        let   hashVal  = 0;
        for (let i = 0; i < (a.name || '').length; i++) {
            hashVal = (hashVal * 31 + (a.name || '').charCodeAt(i)) & 0xffff;
        }
        const avatarColor  = AVATAR_COLORS[hashVal % AVATAR_COLORS.length];
        const isCustomer   = a.accountStatus === 'Customer';
        const cardClass    = isCustomer
            ? 'acct-card acct-card--customer acct-card--targeted'
            : 'acct-card acct-card--prospect-opps acct-card--targeted';
        const faviconUrl   = a.website
            ? `https://www.google.com/s2/favicons?domain=${encodeURIComponent(a.website)}&sz=32`
            : null;
        return {
            ...a,
            sfUrl:                     `/lightning/r/Account/${a.id}/view`,
            lastActivityDateFormatted:  a.lastActivityDate ? this.fmtDate(a.lastActivityDate) : '—',
            lastGongCallDateFormatted:  a.lastGongCallDate ? this.fmtDate(a.lastGongCallDate) : '—',
            activityClass: daysSinceActivity > 30 ? 'stale-text' : 'da-date',
            gongClass:     daysSinceGong     > 30 ? 'stale-text' : 'da-date',
            threadClass:   (a.contactCount || 0) >= 3 ? 'healthy-text'
                         : (a.contactCount || 0) === 0  ? 'stale-text' : 'da-date',
            avatarInitial:  initial,
            avatarStyle:    `background-color:${avatarColor};`,
            faviconUrl,
            arrFormatted:   a.arr          ? CURRENCY.format(a.arr)          : null,
            tamFormatted:   a.estimatedTam ? CURRENCY.format(a.estimatedTam) : null,
            showArr:        isCustomer && !!a.arr,
            showStatusPill: !isCustomer && !!a.accountStatus,
            cardClass
        };
    }

    enrichOpp(o) {
        const s = o.stageName || '';
        let stageCls = 'stage-badge stage-badge--s1';
        if (s === '2 - Discovery') stageCls = 'stage-badge stage-badge--s2';
        else if (s === '3 - POV' || s === '4 - Proposal' || s === '5 - Contracting') stageCls = 'stage-badge stage-badge--s3';
        const daysSinceActivity = o.lastActivityDate ? Math.floor((new Date() - new Date(o.lastActivityDate)) / 86400000) : 999;
        const daysSinceGong     = o.lastGongCallDate ? Math.floor((new Date() - new Date(o.lastGongCallDate)) / 86400000) : 999;
        let oppCardClass = 'acct-card';
        if (o.isStale) {
            oppCardClass += ' opp-card--stale';
        } else if (s.startsWith('5') || s.startsWith('6') || s.startsWith('7')) {
            oppCardClass += ' opp-card--late';
        } else if (s.startsWith('3') || s.startsWith('4')) {
            oppCardClass += ' opp-card--mid';
        } else {
            oppCardClass += ' opp-card--early';
        }
        return {
            ...o,
            sfUrl:                    `/lightning/r/Opportunity/${o.id}/view`,
            amountFormatted:           CURRENCY.format(o.amount || 0),
            lastActivityDateFormatted: o.lastActivityDate ? this.fmtDate(o.lastActivityDate) : '—',
            lastGongCallDateFormatted: o.lastGongCallDate ? this.fmtDate(o.lastGongCallDate) : '—',
            stageBadgeClass:  stageCls,
            oppCardClass,
            daysClass:        o.isStale ? 'do-days do-days--stale' : 'do-days',
            activityDateClass: daysSinceActivity > 30 ? 'stale-text' : 'da-date',
            gongDateClass:     daysSinceGong     > 30 ? 'stale-text' : 'da-date',
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

    // ─── Computed — pipeline target ──────────────────────────────────────────

    get qt()                       { return this.data?.quarterlyTarget || {}; }
    get pipelinePercent()          { return pct(this.qt.pipelineActual, this.qt.pipelineTarget); }
    get pipelineActualFormatted()  { return CURRENCY.format(this.qt.pipelineActual  || 0); }
    get pipelineTargetFormatted()  { return CURRENCY.format(this.qt.pipelineTarget  || 0); }
    get pipelineGapFormatted() {
        return CURRENCY.format(Math.max(0, (this.qt.pipelineTarget || 0) - (this.qt.pipelineActual || 0)));
    }
    get progressBarStyle() {
        const w = this.pipelinePercent;
        const hue = Math.round(w * 1.2); // 0% = red (0°), 100% = green (120°)
        return `width:${w}%;background-color:hsl(${hue},72%,42%);`;
    }
    get stageCards() {
        // Class computation moved to c-pipe-gen-stage-card child component
        return (this.qt.stageCards || []).map(sc => ({
            ...sc,
            amountFormatted: CURRENCY.format(sc.amount || 0)
        }));
    }

    // ─── Computed — opps by stage ────────────────────────────────────────────

    get inFlightOppsByStage() {
        const opps = this.data?.inFlightOpps || [];
        // Source stage order from the dashboard payload (CMT-backed PipeGen_Stage__mdt
        // ordered by Stage_Order__c). Avoids drift between Apex and LWC.
        const stageOrder = (this.qt?.stageCards || []).map(s => s.stageName);
        const grouped = {};
        opps.forEach(o => {
            const s = o.stageName || 'Other';
            if (!grouped[s]) grouped[s] = [];
            grouped[s].push(o);
        });
        const result = [];
        stageOrder.forEach(s => {
            if (grouped[s]) { result.push({ key: s, label: s, opps: grouped[s] }); delete grouped[s]; }
        });
        Object.keys(grouped).sort().forEach(s => result.push({ key: s, label: s, opps: grouped[s] }));
        return result;
    }

    // ─── Computed — commits ───────────────────────────────────────────────────

    get netNewCommits() {
        return (this.data?.thisWeekCommits || [])
            .filter(c => c.Motion_Type__c === 'Net New')
            .slice()
            .sort(commitStatusSort);
    }
    get progressionCommits() {
        return (this.data?.thisWeekCommits || [])
            .filter(c => c.Motion_Type__c === 'Progression')
            .slice()
            .sort(commitStatusSort);
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

    get sortOptions() {
        return [
            { label: 'Name',          value: 'name' },
            { label: 'Last Activity', value: 'activityDate' },
            { label: '# Contacts',    value: 'contactCount' }
        ];
    }

    // ─── Computed — account segments ─────────────────────────────────────────

    get sortedFilteredCards() {
        const term = this.cardSearchTerm.toLowerCase();
        let cards = term.length >= 2
            ? this.accountCards.filter(c =>
                c.name.toLowerCase().includes(term) ||
                (c.industry  || '').toLowerCase().includes(term) ||
                (c.accountStatus || '').toLowerCase().includes(term))
            : [...this.accountCards];

        if (this.accountSortBy === 'activityDate') {
            cards.sort((a, b) => {
                const da = a.lastActivityDate ? new Date(a.lastActivityDate) : new Date(0);
                const db = b.lastActivityDate ? new Date(b.lastActivityDate) : new Date(0);
                return db - da;
            });
        } else if (this.accountSortBy === 'contactCount') {
            cards.sort((a, b) => (b.contactCount || 0) - (a.contactCount || 0));
        } else {
            cards.sort((a, b) => (a.name || '').localeCompare(b.name || ''));
        }
        return cards;
    }

    get accountSegments() {
        const segMap = {};
        for (const seg of SEGMENT_ORDER) segMap[seg] = [];
        for (const c of this.sortedFilteredCards) {
            const seg = c.segment || 'Other';
            const bucket = segMap[seg] ? seg : 'Other';
            segMap[bucket].push(this.applyCardClass(c));
        }
        return SEGMENT_ORDER
            .filter(seg => segMap[seg].length > 0)
            .map(seg => ({ key: seg, label: seg, cards: segMap[seg] }));
    }

    get hasNoSegments()    { return this.accountSegments.length === 0; }

    get targetedCards() {
        return this.accountCards
            .filter(c => c.effectiveTargeted)
            .map(c => this.applyCardClass(c));
    }
    get hasTargetedCards() { return this.targetedCards.length > 0; }

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
        if      (c.accountStatus === 'Customer')    cls += ' acct-card--customer';
        else if ((c.openOppCount || 0) > 0)          cls += ' acct-card--prospect-opps';
        else                                          cls += ' acct-card--prospect-no-opps';
        if (c.effectiveTargeted)                      cls += ' acct-card--targeted';
        if (isPending && c.effectiveTargeted)         cls += ' acct-card--pending-add';
        if (isPending && !c.effectiveTargeted)        cls += ' acct-card--pending-remove';

        const initial = (c.name || '?').charAt(0).toUpperCase();
        let hashVal = 0;
        for (let i = 0; i < (c.name || '').length; i++) {
            hashVal = (hashVal * 31 + (c.name || '').charCodeAt(i)) & 0xffff;
        }
        const avatarColor  = AVATAR_COLORS[hashVal % AVATAR_COLORS.length];
        const avatarStyle  = `background-color:${avatarColor};`;
        const faviconUrl   = c.website ? `https://www.google.com/s2/favicons?domain=${encodeURIComponent(c.website)}&sz=32` : null;

        return {
            ...c,
            cardClass: cls,
            isPending,
            avatarInitial: initial,
            avatarStyle,
            faviconUrl,
            arrFormatted:  c.arr          ? CURRENCY.format(c.arr)          : null,
            tamFormatted:  c.estimatedTam ? CURRENCY.format(c.estimatedTam) : null,
            activityFmt:   c.lastActivityDate ? this.fmtDate(c.lastActivityDate) : '—',
            showArr:       c.accountStatus === 'Customer' && !!c.arr
        };
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
        const id = e.detail?.id || e.currentTarget?.dataset?.id;
        try {
            await deleteCommit({ commitId: id });
            this.data = { ...this.data, thisWeekCommits: (this.data.thisWeekCommits || []).filter(c => c.Id !== id) };
            this.toast('Removed', 'Commit deleted.', 'success');
        } catch (err) {
            this.toast('Error', 'Could not delete commit.', 'error');
        }
    }

    async handleMarkMEDDPICCComplete(e) {
        const id = e.detail?.id || e.currentTarget?.dataset?.id;
        try {
            await markCommitComplete({ commitId: id });
            await this.loadData();
        } catch (err) {
            this.toast('Error', 'Could not mark commit complete.', 'error');
        }
    }

    async handleCarryForward() {
        this.isCarryingForward = true;
        try {
            const carried = await carryForwardIncompleteCommits();
            const count = Array.isArray(carried) ? carried.length : 0;
            if (count > 0) {
                await this.loadData();
                this.toast('Carried Forward', `${count} incomplete commit${count === 1 ? '' : 's'} copied from last week.`, 'success');
            } else {
                this.toast('Nothing to Carry', 'No incomplete commits from last week.', 'info');
            }
        } catch (e) {
            this.toast('Error', e.body?.message || 'Could not carry forward commits.', 'error');
        } finally {
            this.isCarryingForward = false;
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
        const id = e.detail?.id || e.currentTarget?.dataset?.id;
        this.accountCards = this.accountCards.map(c =>
            c.id === id ? { ...c, effectiveTargeted: !c.effectiveTargeted } : c
        );
    }

    handleCardSearch(e) {
        this.cardSearchTerm = e.detail.value || '';
    }

    handleSortChange(e) {
        this.accountSortBy = e.detail.value;
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
            this.loadData();
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

function commitStatusSort(a, b) {
    const order = { 'Completed': 0, 'Partial': 1, 'Not Started': 2 };
    return (order[a.Completion_Status__c] ?? 2) - (order[b.Completion_Status__c] ?? 2);
}
