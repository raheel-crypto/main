import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getMyGTMAs              from '@salesforce/apex/PipeGenSharedController.getMyGTMAs';
import getSharedDashboardData  from '@salesforce/apex/PipeGenSharedController.getSharedDashboardData';
import createSharedCommit      from '@salesforce/apex/PipeGenSharedController.createSharedCommit';
import createPartnerCommit     from '@salesforce/apex/PipeGenSharedController.createPartnerCommit';
import toggleCommitComplete    from '@salesforce/apex/PipeGenSharedController.toggleCommitComplete';
import deleteCommit            from '@salesforce/apex/PipeGenSharedController.deleteCommit';

const CURRENCY   = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD', maximumFractionDigits: 0 });
const SHORT_DATE = new Intl.DateTimeFormat('en-US', { month: 'short', day: 'numeric' });
const AVATAR_COLORS = ['#3b82f6','#8b5cf6','#ec4899','#f59e0b','#10b981','#06b6d4','#ef4444','#6366f1'];

const AE_COMMIT_TYPES = [
    { label: 'First Meeting Booked',   value: 'First Meeting Booked' },
    { label: 'Multi-Thread Intro',      value: 'Multi-Thread Intro' },
    { label: 'Champion-Led Referral',   value: 'Champion-Led Referral' },
    { label: 'Exec Outreach Sequence',  value: 'Exec Outreach Sequence' },
    { label: 'Discovery Call',          value: 'Discovery Call - Economic Buyer' },
    { label: 'Technical Validation',    value: 'Technical Validation' },
    { label: 'Exec Alignment',          value: 'Exec Alignment' }
];

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
    ownership:      'shared',
    commitType:     '',
    description:    '',
    accountId:      null,
    accountName:    '',
    committedCount: 1
});

export default class PipeGenSharedDashboard extends LightningElement {

    @track gtmas           = [];
    @track selectedGtmaId  = null;
    @track data            = null;
    @track isLoading       = true;
    @track isLoadingData   = false;
    @track errorMessage    = null;
    @track showCommitForm  = false;
    @track isSaving        = false;
    @track newCommit       = EMPTY_COMMIT();
    @track accountSearchResults = [];

    // ─── Lifecycle ──────────────────────────────────────────────────────────

    async connectedCallback() {
        try {
            const raw = await getMyGTMAs();
            this.gtmas = raw || [];
            if (this.gtmas.length === 1) {
                this.selectedGtmaId = this.gtmas[0].id;
                await this.loadDashboardData();
            }
        } catch (e) {
            this.errorMessage = e.body?.message || 'Could not load GTMAs.';
        } finally {
            this.isLoading = false;
        }
    }

    async loadDashboardData() {
        if (!this.selectedGtmaId) return;
        this.isLoadingData = true;
        try {
            const raw = await getSharedDashboardData({ gtmaId: this.selectedGtmaId });
            this.data = this.processData(raw);
        } catch (e) {
            this.errorMessage = e.body?.message || 'Could not load shared dashboard data.';
        } finally {
            this.isLoadingData = false;
        }
    }

    processData(raw) {
        return {
            accounts:     (raw.accounts     || []).map(a => this.enrichAccount(a)),
            sharedCommits: (raw.sharedCommits || []).map(c => this.enrichCommit(c, 'shared')),
            aeCommits:    (raw.aeCommits    || []).map(c => this.enrichCommit(c, 'ae')),
            gtmaCommits:  (raw.gtmaCommits  || []).map(c => this.enrichCommit(c, 'gtma'))
        };
    }

    enrichCommit(c, ownerType) {
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
            progressLabel:  `${actual} / ${committed}`,
            refName,
            statusDotClass: status === 'Completed' ? 'status-dot status-dot--complete'
                          : status === 'Partial'   ? 'status-dot status-dot--partial'
                          :                          'status-dot status-dot--pending',
            commitCardClass: `commit-card commit-card--${ownerType} commit-card--${statusSuffix}`,
            toggleLabel:     status === 'Completed' ? 'Unmark' : 'Mark Complete',
            toggleBtnClass:  `commit-toggle${status === 'Completed' ? ' commit-toggle--done' : ' commit-toggle--undone'}`
        };
    }

    enrichAccount(a) {
        const initial = (a.name || '?').charAt(0).toUpperCase();
        let hashVal = 0;
        for (let i = 0; i < (a.name || '').length; i++) {
            hashVal = (hashVal * 31 + (a.name || '').charCodeAt(i)) & 0xffff;
        }
        const avatarColor = AVATAR_COLORS[hashVal % AVATAR_COLORS.length];
        return {
            ...a,
            avatarInitial: initial,
            avatarStyle:   `background-color:${avatarColor};`,
            faviconUrl:    a.website ? `https://www.google.com/s2/favicons?domain=${encodeURIComponent(a.website)}&sz=32` : null
        };
    }

    // ─── Computed ────────────────────────────────────────────────────────────

    get isReady()        { return !this.isLoading; }
    get hasError()       { return !!this.errorMessage; }
    get hasNoGtmas()     { return !this.isLoading && this.gtmas.length === 0; }
    get noGtmaSelected() { return !this.isLoading && this.gtmas.length > 0 && !this.selectedGtmaId; }
    get hasGtmaSelected(){ return !this.isLoading && !!this.selectedGtmaId && !!this.data; }

    get gtmaOptions() {
        return this.gtmas.map(g => ({ label: g.name, value: g.id }));
    }

    get hasAccounts()     { return (this.data?.accounts     || []).length > 0; }
    get hasSharedCommits(){ return (this.data?.sharedCommits || []).length > 0; }
    get hasAeCommits()    { return (this.data?.aeCommits    || []).length > 0; }
    get hasGtmaCommits()  { return (this.data?.gtmaCommits  || []).length > 0; }
    get hasAccountResults(){ return this.accountSearchResults.length > 0; }

    get accountCountLabel() { return `${(this.data?.accounts || []).length} accounts`; }
    get sharedCountLabel()  { return `${(this.data?.sharedCommits || []).length}`; }
    get aeCountLabel()      { return `${(this.data?.aeCommits || []).length}`; }
    get gtmaCountLabel()    { return `${(this.data?.gtmaCommits || []).length}`; }

    get ownershipOptions() {
        return [
            { label: 'Shared', value: 'shared' },
            { label: 'AE Only', value: 'ae' },
            { label: 'GTMA Only', value: 'gtma' }
        ];
    }

    get commitTypeOptions() {
        return this.newCommit.ownership === 'gtma' ? GTMA_COMMIT_TYPES : AE_COMMIT_TYPES;
    }

    // ─── Handlers ───────────────────────────────────────────────────────────

    async handleGtmaChange(e) {
        this.selectedGtmaId = e.detail.value;
        this.data = null;
        await this.loadDashboardData();
    }

    openCommitForm()  { this.showCommitForm = true;  this.newCommit = EMPTY_COMMIT(); this.accountSearchResults = []; }
    closeCommitForm() { this.showCommitForm = false; }

    handleOwnershipChange(e)   { this.newCommit = { ...EMPTY_COMMIT(), ownership: e.detail.value }; this.accountSearchResults = []; }
    handleCommitTypeChange(e)  { this.newCommit = { ...this.newCommit, commitType:    e.detail.value }; }
    handleDescriptionChange(e) { this.newCommit = { ...this.newCommit, description:   e.detail.value }; }
    handleCountChange(e)       { this.newCommit = { ...this.newCommit, committedCount: parseInt(e.detail.value, 10) || 1 }; }

    handleAccountSearch(e) {
        const term = e.detail.value || '';
        this.newCommit = { ...this.newCommit, accountName: term };
        this.accountSearchResults = term.length >= 2
            ? (this.data?.accounts || [])
                .filter(a => a.name.toLowerCase().includes(term.toLowerCase()))
                .slice(0, 6)
                .map(a => ({ id: a.id, name: a.name }))
            : [];
    }

    selectAccount(e) {
        this.newCommit = { ...this.newCommit, accountId: e.currentTarget.dataset.id, accountName: e.currentTarget.dataset.name };
        this.accountSearchResults = [];
    }

    async saveNewCommit() {
        if (!this.newCommit.commitType || !this.newCommit.description) {
            this.toast('Missing Fields', 'Commit Type and Description are required.', 'error');
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
            let saved;
            if (this.newCommit.ownership === 'shared') {
                saved = await createSharedCommit({ commitRecord: record, gtmaId: this.selectedGtmaId });
                this.data = {
                    ...this.data,
                    sharedCommits: [...(this.data.sharedCommits || []), this.enrichCommit(saved, 'shared')]
                };
            } else if (this.newCommit.ownership === 'ae') {
                saved = await createPartnerCommit({ commitRecord: record, targetRepId: null });
                this.data = {
                    ...this.data,
                    aeCommits: [...(this.data.aeCommits || []), this.enrichCommit(saved, 'ae')]
                };
            } else {
                saved = await createPartnerCommit({ commitRecord: record, targetRepId: this.selectedGtmaId });
                this.data = {
                    ...this.data,
                    gtmaCommits: [...(this.data.gtmaCommits || []), this.enrichCommit(saved, 'gtma')]
                };
            }
            this.closeCommitForm();
            this.toast('Saved', 'Commit recorded.', 'success');
        } catch (e) {
            this.toast('Error', e.body?.message || 'Could not save commit.', 'error');
        } finally {
            this.isSaving = false;
        }
    }

    async handleToggleComplete(e) {
        const id   = e.currentTarget.dataset.id;
        const list = e.currentTarget.dataset.list;
        try {
            const updated = await toggleCommitComplete({ commitId: id });
            this.updateCommitInList(id, list, updated);
        } catch (err) {
            this.toast('Error', 'Could not update commit status.', 'error');
        }
    }

    async handleDeleteCommit(e) {
        const id   = e.currentTarget.dataset.id;
        const list = e.currentTarget.dataset.list;
        try {
            await deleteCommit({ commitId: id });
            this.removeCommitFromList(id, list);
            this.toast('Removed', 'Commit deleted.', 'success');
        } catch (err) {
            this.toast('Error', 'Could not delete commit.', 'error');
        }
    }

    updateCommitInList(id, list, updated) {
        const key = list === 'shared' ? 'sharedCommits' : list === 'ae' ? 'aeCommits' : 'gtmaCommits';
        const ownerType = list;
        this.data = {
            ...this.data,
            [key]: (this.data[key] || []).map(c => c.Id === id ? this.enrichCommit(updated, ownerType) : c)
        };
    }

    removeCommitFromList(id, list) {
        const key = list === 'shared' ? 'sharedCommits' : list === 'ae' ? 'aeCommits' : 'gtmaCommits';
        this.data = {
            ...this.data,
            [key]: (this.data[key] || []).filter(c => c.Id !== id)
        };
    }

    // ─── Utilities ──────────────────────────────────────────────────────────

    fmtDate(dateStr) {
        if (!dateStr) return '—';
        return SHORT_DATE.format(new Date(dateStr));
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
