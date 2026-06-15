import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getGTMADashboardData          from '@salesforce/apex/PipeGenGTMAController.getGTMADashboardData';
import saveCommit                    from '@salesforce/apex/PipeGenGTMAController.saveCommit';
import deleteCommit                  from '@salesforce/apex/PipeGenGTMAController.deleteCommit';
import toggleCommitComplete          from '@salesforce/apex/PipeGenGTMAController.toggleCommitComplete';
import getGTMAAccountsForSelection   from '@salesforce/apex/PipeGenGTMAController.getGTMAAccountsForSelection';
import updateGTMATargetAccounts      from '@salesforce/apex/PipeGenGTMAController.updateGTMATargetAccounts';
import carryForwardGTMACommits       from '@salesforce/apex/PipeGenGTMAController.carryForwardGTMACommits';
import getPriorWeekCommits           from '@salesforce/apex/PipeGenGTMAController.getPriorWeekCommits';
import searchAllAccounts             from '@salesforce/apex/PipeGenGTMAController.searchAllAccounts';
import addGTMA2Target                from '@salesforce/apex/PipeGenGTMAController.addGTMA2Target';
import removeGTMA2Target             from '@salesforce/apex/PipeGenGTMAController.removeGTMA2Target';

const CURRENCY   = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD', maximumFractionDigits: 0 });
const SHORT_DATE = new Intl.DateTimeFormat('en-US', { month: 'short', day: 'numeric' });

const SEGMENT_ORDER = ['Expansion', 'Early Stage', 'Uncracked', 'Recent Closed Lost', 'No Opportunities', 'Other'];
const ALPHABET = ['A','B','C','D','E','F','G','H','I','J','K','L','M','N','O','P','Q','R','S','T','U','V','W','X','Y','Z'];
const AVATAR_COLORS = ['#3b82f6','#8b5cf6','#ec4899','#f59e0b','#10b981','#06b6d4','#ef4444','#6366f1'];

const GTMA_COMMIT_TYPES = [
    { label: 'Meeting Booked',          value: 'Meeting Booked' },
    { label: 'Cold Call Made',           value: 'Cold Call Made' },
    { label: 'LinkedIn Outreach',        value: 'LinkedIn Outreach' },
    { label: 'Email Sequence Launched',  value: 'Email Sequence Launched' },
    { label: 'Event Attendance',         value: 'Event Attendance' },
    { label: 'Referral Intro',           value: 'Referral Intro' },
    { label: 'Executive Briefing',       value: 'Executive Briefing' }
];

const EMPTY_COMMIT = () => ({
    commitType:     '',
    description:    '',
    accountId:      null,
    accountName:    '',
    committedCount: 1
});

export default class PipeGenGTMADashboard extends LightningElement {

    // ─── Dashboard state ─────────────────────────────────────────────────────
    @track data                 = null;
    @track isLoading            = true;
    @track errorMessage         = null;
    @track showCommitForm       = false;
    @track isSaving             = false;
    @track isCarryingForward    = false;
    @track showCarryModal       = false;
    @track carryModalCommits    = [];
    @track isLoadingCarry       = false;
    @track accountSearchResults = [];
    @track newCommit            = EMPTY_COMMIT();

    // ─── GTMA2 tier flag ────────────────────────────────────────────────────
    @track isGTMA2 = false;

    // ─── Account card tab state — GTMA1 ─────────────────────────────────────
    @track accountCards       = [];
    @track accountCardsLoaded = false;
    @track isLoadingCards     = false;
    @track isSavingTargets    = false;
    @track cardSearchTerm     = '';
    @track accountSortBy      = 'name';
    @track alphaFilter        = 'All';

    // ─── Active tab tracking — prevents tab reset on re-render ──────────────
    @track activeTab = 'dashboard';

    // ─── Week navigation ─────────────────────────────────────────────────────
    @track selectedWeekOffset = 0;  // -1 = last week, 0 = this week, 1 = next week

    // ─── GTMA2 account search state ──────────────────────────────────────────
    @track gtma2SearchTerm    = '';
    @track gtma2SearchResults = [];
    @track isSearching        = false;
    _searchTimer              = null;

    // ─── Lifecycle ──────────────────────────────────────────────────────────

    connectedCallback() {
        this.loadData();
    }

    // ─── Data Loading ────────────────────────────────────────────────────────

    async loadData() {
        this.isLoading    = true;
        this.errorMessage = null;
        try {
            const raw    = await getGTMADashboardData({ weekOffset: this.selectedWeekOffset });
            this.isGTMA2 = raw.isGTMA2 || false;
            this.data    = this.processData(raw);
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
            thisWeekCommits: (raw.thisWeekCommits || []).map(c => this.enrichCommit(c))
        };
    }

    enrichCommit(c) {
        const actual    = c.Actual_Count__c    || 0;
        const committed = c.Committed_Count__c || 1;
        const status    = c.Completion_Status__c || 'Not Started';
        const statusSuffix = status === 'Completed' ? 'complete'
                           : status === 'Partial'   ? 'partial'
                           :                          'pending';
        const acctRel = c.Target_Account__r || null;
        const refName = (acctRel && acctRel.Name) || '';
        return {
            ...c,
            Target_Account__r: acctRel,
            progressLabel:     `${actual} / ${committed}`,
            refName,
            statusDotClass:  status === 'Completed' ? 'status-dot status-dot--complete'
                           : status === 'Partial'   ? 'status-dot status-dot--partial'
                           :                          'status-dot status-dot--pending',
            commitCardClass: `commit-card commit-card--gtma commit-card--${statusSuffix}`,
            toggleLabel:     status === 'Completed' ? 'Unmark' : 'Mark Complete',
            toggleBtnClass:  `commit-toggle${status === 'Completed' ? ' commit-toggle--done' : ' commit-toggle--undone'}`
        };
    }

    enrichAccount(a, today) {
        const daysSinceActivity = a.lastActivityDate ? this.daysSince(a.lastActivityDate, today) : 999;
        const daysSinceGong     = a.lastGongCallDate ? this.daysSince(a.lastGongCallDate, today)  : 999;
        const initial  = (a.name || '?').charAt(0).toUpperCase();
        let   hashVal  = 0;
        for (let i = 0; i < (a.name || '').length; i++) {
            hashVal = (hashVal * 31 + (a.name || '').charCodeAt(i)) & 0xffff;
        }
        const avatarColor = AVATAR_COLORS[hashVal % AVATAR_COLORS.length];
        const isCustomer  = a.accountStatus === 'Customer';
        const cardClass   = isCustomer
            ? 'acct-card acct-card--customer acct-card--targeted'
            : 'acct-card acct-card--prospect-opps acct-card--targeted';
        const faviconUrl  = a.website
            ? `https://www.google.com/s2/favicons?domain=${encodeURIComponent(a.website)}&sz=32`
            : null;
        return {
            ...a,
            sfUrl:                      `/lightning/r/Account/${a.id}/view`,
            lastActivityDateFormatted:  a.lastActivityDate ? this.fmtDate(a.lastActivityDate) : '—',
            lastGongCallDateFormatted:  a.lastGongCallDate ? this.fmtDate(a.lastGongCallDate)  : '—',
            activityClass: daysSinceActivity > 30 ? 'stale-text' : 'da-date',
            gongClass:     daysSinceGong     > 30 ? 'stale-text' : 'da-date',
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

    // ─── Computed — visibility ─────────────────────────────────────────────────

    get isReady()           { return !this.isLoading && !this.errorMessage && !!this.data; }
    get hasError()          { return !!this.errorMessage; }
    get hasAccounts()       { return (this.data?.targetAccounts?.length || 0) > 0; }
    get hasCommits()        { return this.allCommits.length > 0; }
    get hasAccountResults() { return this.accountSearchResults.length > 0; }
    get accountCountLabel() { return `${this.data?.targetAccounts?.length || 0} accounts`; }

    // ─── Computed — week navigation ────────────────────────────────────────────────
    get lastWeekBtnClass() { return `week-nav-btn${this.selectedWeekOffset === -1 ? ' week-nav-btn--active' : ''}`; }
    get thisWeekBtnClass() { return `week-nav-btn${this.selectedWeekOffset ===  0 ? ' week-nav-btn--active' : ''}`; }
    get nextWeekBtnClass() { return `week-nav-btn${this.selectedWeekOffset ===  1 ? ' week-nav-btn--active' : ''}`; }
    get scorecardLabel()   { return this.data?.scorecardLabel || 'Prior Week'; }
    get carryForwardLabel() {
        if (this.selectedWeekOffset === 1)  return '↷ Pull from This Week';
        if (this.selectedWeekOffset === -1) return '↷ Copy to This Week';
        return '↷ Carry Forward';
    }
    get showCarryForward() { return true; }

    // ─── Computed — carry-forward modal ────────────────────────────────────────────
    get carryModalTitle() {
        return this.selectedWeekOffset === 1 ? 'Copy from This Week' : 'Copy from Last Week';
    }
    get carryIncompleteCommits() {
        return this.carryModalCommits.filter(c => c.Completion_Status__c !== 'Completed');
    }
    get carryCompletedCommits() {
        return this.carryModalCommits.filter(c => c.Completion_Status__c === 'Completed');
    }
    get hasCarryIncomplete() { return this.carryIncompleteCommits.length > 0; }
    get hasCarryCompleted()  { return this.carryCompletedCommits.length > 0; }
    get selectedCarryCount() { return this.carryModalCommits.filter(c => c.selected).length; }
    get carryConfirmLabel()  { return `Copy Selected (${this.selectedCarryCount})`; }
    get hasCarrySelection()  { return this.selectedCarryCount > 0; }
    get noCarryCommits()     { return !this.isLoadingCarry && this.carryModalCommits.length === 0; }

    // ─── Computed — weekly target header ───────────────────────────────────────────

    get wt() { return this.data?.weeklyTarget || {}; }

    get weeklyPercent() {
        if (!this.wt.target || this.wt.target <= 0) return null;
        return Math.min(100, Math.round(((this.wt.completed || 0) / this.wt.target) * 100));
    }

    get showProgressBar() { return this.weeklyPercent !== null; }

    get weeklyProgressStyle() {
        const w   = this.weeklyPercent || 0;
        const hue = Math.round(w * 1.2);
        return `width:${w}%;background-color:hsl(${hue},72%,42%);`;
    }

    get weeklyHeaderLabel() {
        const wt = this.wt;
        if (wt.target && wt.target > 0) {
            return `${wt.weekLabel || ''} · ${wt.completed || 0} / ${wt.target} activities complete`;
        }
        return `${wt.weekLabel || ''} · ${wt.total || 0} activities tracked`;
    }

    // ─── Computed — commits ───────────────────────────────────────────────────

    get allCommits() {
        return (this.data?.thisWeekCommits || [])
            .slice()
            .sort(commitStatusSort);
    }

    // ─── Computed — scorecard ───────────────────────────────────────────────────

    get scorecard() {
        const sc = this.data?.lastWeekScorecard || {};
        return {
            commitsCompleted:   sc.commitsCompleted   || 0,
            commitsTotal:       sc.commitsTotal       || 0,
            accountsTouched:    sc.accountsTouched    || 0,
            pipelineInfluence:  sc.pipelineInfluence  || 0
        };
    }

    // ─── Computed — commit form options ───────────────────────────────────────────

    get commitTypeOptions() { return GTMA_COMMIT_TYPES; }

    get sortOptions() {
        return [
            { label: 'Name',          value: 'name' },
            { label: 'Last Activity', value: 'activityDate' },
            { label: '# Contacts',    value: 'contactCount' }
        ];
    }

    // ─── Computed — GTMA1 account segments ────────────────────────────────────────

    get alphaLetters() {
        return ['All', ...ALPHABET].map(l => ({
            key:      l,
            label:    l,
            btnClass: `alpha-pill${this.alphaFilter === l ? ' alpha-pill--active' : ''}`
        }));
    }

    get sortedFilteredCards() {
        const term = this.cardSearchTerm.toLowerCase();
        let cards = term.length >= 2
            ? this.accountCards.filter(c =>
                c.name.toLowerCase().includes(term) ||
                (c.industry      || '').toLowerCase().includes(term) ||
                (c.accountStatus || '').toLowerCase().includes(term))
            : [...this.accountCards];

        if (this.alphaFilter !== 'All') {
            cards = cards.filter(c => (c.name || '').toUpperCase().startsWith(this.alphaFilter));
        }

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
            const seg    = c.segment || 'Other';
            const bucket = segMap[seg] ? seg : 'Other';
            segMap[bucket].push(this.applyCardClass(c));
        }
        return SEGMENT_ORDER
            .filter(seg => segMap[seg].length > 0)
            .map(seg => ({ key: seg, label: seg, cards: segMap[seg] }));
    }

    get hasNoSegments()   { return this.accountSegments.length === 0; }

    get targetedCards() {
        return this.accountCards
            .filter(c => c.effectiveTargeted)
            .map(c => this.applyCardClass(c));
    }
    get hasTargetedCards() { return this.targetedCards.length > 0; }

    get pendingChanges()    { return this.accountCards.filter(c => c.effectiveTargeted !== c.isTargeted); }
    get hasPendingChanges() { return this.pendingChanges.length > 0; }
    get pendingCount()      { return this.pendingChanges.length; }
    get pendingLabel()      { return `Save ${this.pendingCount} change${this.pendingCount === 1 ? '' : 's'}`; }
    get pendingCountLabel() { return `${this.pendingCount} unsaved change${this.pendingCount === 1 ? '' : 's'}`; }
    get targetedCardCount() { return this.accountCards.filter(c => c.effectiveTargeted).length; }
    get totalCardCount()    { return this.accountCards.length; }

    // ─── Computed — GTMA2 ────────────────────────────────────────────────────────

    get gtma2Cards() {
        return this.accountCards.map(c => this.applyCardClass(c));
    }
    get hasAccountCards()       { return this.accountCards.length > 0; }
    get hasGTMA2SearchResults() { return this.gtma2SearchResults.length > 0; }
    get showGTMA2NoResults() {
        return !this.isSearching && this.gtma2SearchTerm.length >= 2 && this.gtma2SearchResults.length === 0;
    }

    applyCardClass(c) {
        const isPending = c.effectiveTargeted !== c.isTargeted;
        let cls = 'acct-card';
        if      (c.accountStatus === 'Customer') cls += ' acct-card--customer';
        else if ((c.openOppCount || 0) > 0)       cls += ' acct-card--prospect-opps';
        else                                       cls += ' acct-card--prospect-no-opps';
        if (c.effectiveTargeted)                   cls += ' acct-card--targeted';
        if (isPending &&  c.effectiveTargeted)     cls += ' acct-card--pending-add';
        if (isPending && !c.effectiveTargeted)     cls += ' acct-card--pending-remove';

        const initial = (c.name || '?').charAt(0).toUpperCase();
        let hashVal = 0;
        for (let i = 0; i < (c.name || '').length; i++) {
            hashVal = (hashVal * 31 + (c.name || '').charCodeAt(i)) & 0xffff;
        }
        const avatarColor = AVATAR_COLORS[hashVal % AVATAR_COLORS.length];
        const faviconUrl  = c.website
            ? `https://www.google.com/s2/favicons?domain=${encodeURIComponent(c.website)}&sz=32`
            : null;

        return {
            ...c,
            cardClass:     cls,
            isPending,
            avatarInitial: initial,
            avatarStyle:   `background-color:${avatarColor};`,
            faviconUrl,
            arrFormatted:  c.arr          ? CURRENCY.format(c.arr)          : null,
            tamFormatted:  c.estimatedTam ? CURRENCY.format(c.estimatedTam) : null,
            activityFmt:   c.lastActivityDate ? this.fmtDate(c.lastActivityDate) : '—',
            showArr:       c.accountStatus === 'Customer' && !!c.arr
        };
    }

    // ─── Handlers — header ────────────────────────────────────────────────────

    async handleRefresh() {
        this.accountCardsLoaded = false;
        await this.loadData();
    }

    handleTabSelect(e) {
        this.activeTab = e.detail.value;
    }

    handleWeekNav(e) {
        const offset = parseInt(e.currentTarget.dataset.offset, 10);
        if (offset === this.selectedWeekOffset) return;
        this.selectedWeekOffset = offset;
        this.accountCardsLoaded = false;
        this.loadData();
    }

    // ─── Commit Form Handlers ───────────────────────────────────────────────────

    openCommitForm()  { this.showCommitForm = true;  this.newCommit = EMPTY_COMMIT(); this.accountSearchResults = []; }
    closeCommitForm() { this.showCommitForm = false; }

    handleCommitTypeChange(e)  { this.newCommit = { ...this.newCommit, commitType:    e.detail.value }; }
    handleDescriptionChange(e) { this.newCommit = { ...this.newCommit, description:   e.detail.value }; }
    handleCountChange(e)       { this.newCommit = { ...this.newCommit, committedCount: parseInt(e.detail.value, 10) || 1 }; }

    handleAccountSearch(e) {
        const term = e.detail.value || '';
        this.newCommit = { ...this.newCommit, accountName: term };
        const pool = [
            ...(this.data?.targetAccounts || []),
            ...this.accountCards
        ];
        const seen = new Set();
        this.accountSearchResults = term.length >= 2
            ? pool
                .filter(a => {
                    if (seen.has(a.id)) return false;
                    seen.add(a.id);
                    return a.name.toLowerCase().includes(term.toLowerCase());
                })
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
            this.toast('Missing Fields', 'Activity Type and Description are required.', 'error');
            return;
        }

        this.isSaving = true;
        const record = {
            Commit_Type__c:        this.newCommit.commitType,
            Commit_Description__c: this.newCommit.description,
            Committed_Count__c:    this.newCommit.committedCount,
            Target_Account__c:     this.newCommit.accountId || null
        };

        try {
            const saved = await saveCommit({ commitRecord: record, weekOffset: this.selectedWeekOffset });
            this.data = {
                ...this.data,
                thisWeekCommits: [...(this.data.thisWeekCommits || []), this.enrichCommit(saved)]
            };
            const wt = { ...(this.data.weeklyTarget || {}) };
            wt.total = (wt.total || 0) + 1;
            this.data = { ...this.data, weeklyTarget: wt };
            this.closeCommitForm();
            this.toast('Commit Saved', 'Your activity commit has been recorded.', 'success');
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
            this.data = {
                ...this.data,
                thisWeekCommits: (this.data.thisWeekCommits || []).filter(c => c.Id !== id)
            };
            this.toast('Removed', 'Commit deleted.', 'success');
        } catch (err) {
            this.toast('Error', 'Could not delete commit.', 'error');
        }
    }

    async handleToggleComplete(e) {
        const id = e.currentTarget.dataset.id;
        try {
            const updated = await toggleCommitComplete({ commitId: id });
            this.data = {
                ...this.data,
                thisWeekCommits: (this.data.thisWeekCommits || []).map(c =>
                    c.Id === id ? this.enrichCommit(updated) : c
                )
            };
        } catch (err) {
            this.toast('Error', 'Could not update commit status.', 'error');
        }
    }

    async handleCarryForward() {
        this.carryModalCommits = [];
        this.showCarryModal    = true;
        this.isLoadingCarry    = true;
        try {
            const apexOffset = Math.max(0, this.selectedWeekOffset);
            const commits    = await getPriorWeekCommits({ weekOffset: apexOffset });
            this.carryModalCommits = (commits || []).map(c => ({
                ...c,
                selected: c.Completion_Status__c !== 'Completed',
                refName:  (c.Target_Account__r && c.Target_Account__r.Name) || ''
            }));
        } catch (e) {
            this.toast('Error', 'Could not load prior week commits.', 'error');
            this.showCarryModal = false;
        } finally {
            this.isLoadingCarry = false;
        }
    }

    handleCarryToggle(e) {
        const id = e.currentTarget.dataset.id;
        this.carryModalCommits = this.carryModalCommits.map(c =>
            c.Id === id ? { ...c, selected: !c.selected } : c
        );
    }

    handleCarrySelectAll() {
        this.carryModalCommits = this.carryModalCommits.map(c => ({ ...c, selected: true }));
    }

    handleCarrySelectIncomplete() {
        this.carryModalCommits = this.carryModalCommits.map(c =>
            ({ ...c, selected: c.Completion_Status__c !== 'Completed' })
        );
    }

    async handleCarryConfirm() {
        const selectedIds = this.carryModalCommits.filter(c => c.selected).map(c => c.Id);
        if (!selectedIds.length) {
            this.toast('Nothing Selected', 'Check at least one commit to copy.', 'info');
            return;
        }
        this.isCarryingForward = true;
        try {
            const apexOffset = Math.max(0, this.selectedWeekOffset);
            const carried    = await carryForwardGTMACommits({ weekOffset: apexOffset, selectedIds });
            const count      = Array.isArray(carried) ? carried.length : 0;
            this.showCarryModal    = false;
            this.carryModalCommits = [];
            await this.loadData();
            const fromLabel = apexOffset === 1 ? 'this week' : 'last week';
            this.toast('Copied', `${count} commit${count === 1 ? '' : 's'} copied from ${fromLabel}.`, 'success');
        } catch (e) {
            this.toast('Error', e.body?.message || 'Could not copy commits.', 'error');
        } finally {
            this.isCarryingForward = false;
        }
    }

    handleCarryCancel() {
        this.showCarryModal    = false;
        this.carryModalCommits = [];
    }

    // ─── GTMA1 Account Cards Handlers ────────────────────────────────────────────

    async handleAccountsTabActive() {
        if (this.accountCardsLoaded) return;
        this.isLoadingCards = true;
        try {
            const raw = await getGTMAAccountsForSelection();
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

    handleCardSearch(e) { this.cardSearchTerm = e.detail.value || ''; this.alphaFilter = 'All'; }
    handleAlphaFilter(e) { this.alphaFilter = e.currentTarget.dataset.letter; }
    handleSortChange(e) { this.accountSortBy  = e.detail.value; }

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
            await updateGTMATargetAccounts({ toTarget, toUntarget });
            this.accountCards = this.accountCards.map(c => ({ ...c, isTargeted: c.effectiveTargeted }));
            this.toast('Saved', `${count} account${count === 1 ? '' : 's'} updated.`, 'success');
            this.loadData();
        } catch (e) {
            this.toast('Error', e.body?.message || 'Could not update accounts.', 'error');
        } finally {
            this.isSavingTargets = false;
        }
    }

    // ─── GTMA2 Account Search Handlers ───────────────────────────────────────────

    handleGTMA2Search(e) {
        const term = e.detail.value || '';
        this.gtma2SearchTerm = term;
        clearTimeout(this._searchTimer);
        if (term.length < 2) { this.gtma2SearchResults = []; return; }
        this._searchTimer = setTimeout(async () => {
            this.isSearching = true;
            try {
                const excludeIds = this.accountCards.map(c => c.id);
                const results    = await searchAllAccounts({ searchTerm: term, excludeIds });
                this.gtma2SearchResults = results.map(a => this.enrichSearchResult(a));
            } catch (err) {
                this.gtma2SearchResults = [];
            } finally {
                this.isSearching = false;
            }
        }, 300);
    }

    enrichSearchResult(a) {
        const name    = a.Name || '';
        const initial = (name || '?').charAt(0).toUpperCase();
        let hashVal = 0;
        for (let i = 0; i < name.length; i++) {
            hashVal = (hashVal * 31 + name.charCodeAt(i)) & 0xffff;
        }
        return {
            id:            a.Id,
            name,
            accountStatus: a.Account_Status__c,
            type:          a.Type,
            avatarInitial: initial,
            avatarStyle:   `background-color:${AVATAR_COLORS[hashVal % AVATAR_COLORS.length]};`,
            faviconUrl:    a.Website
                ? `https://www.google.com/s2/favicons?domain=${encodeURIComponent(a.Website)}&sz=32`
                : null
        };
    }

    async handleAddGTMA2Target(e) {
        const id     = e.currentTarget.dataset.id;
        const result = this.gtma2SearchResults.find(r => r.id === id);
        if (!result) return;
        try {
            await addGTMA2Target({ accountId: id });
            this.accountCards = [...this.accountCards, {
                ...result, isTargeted: true, effectiveTargeted: true,
                openOppCount: 0, segment: 'Other'
            }];
            this.gtma2SearchResults = this.gtma2SearchResults.filter(r => r.id !== id);
            this.toast('Added', `${result.name} added to your targets.`, 'success');
        } catch (err) {
            this.toast('Error', 'Could not add account to targets.', 'error');
        }
    }

    async handleRemoveGTMA2Target(e) {
        const id   = e.currentTarget.dataset.id;
        const card = this.accountCards.find(c => c.id === id);
        if (!card) return;
        try {
            await removeGTMA2Target({ accountId: id });
            this.accountCards = this.accountCards.filter(c => c.id !== id);
            this.toast('Removed', `${card.name} removed from your targets.`, 'success');
        } catch (err) {
            this.toast('Error', 'Could not remove account from targets.', 'error');
        }
    }

    // ─── Utilities ──────────────────────────────────────────────────────────

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

function commitStatusSort(a, b) {
    const order = { 'Completed': 0, 'Partial': 1, 'Not Started': 2 };
    return (order[a.Completion_Status__c] ?? 2) - (order[b.Completion_Status__c] ?? 2);
}
