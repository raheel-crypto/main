import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getBulkMergeCandidates from '@salesforce/apex/AccountDedupeScanController.getBulkMergeCandidates';
import queueGroupsForMerge from '@salesforce/apex/AccountDedupeScanController.queueGroupsForMerge';
import getRecentlyProcessed from '@salesforce/apex/AccountDedupeScanController.getRecentlyProcessed';

const SCENARIO_FILTER_OPTIONS = [
    { label: 'Exact Website (default)', value: 'exactWebsite' },
    { label: 'Exact LinkedIn URL', value: 'exactLinkedIn' },
    { label: 'Name + Normalized Domain', value: 'nameNormalizedDomain' },
    { label: 'Name + Domain Root', value: 'nameDomainRoot' },
    { label: 'Similar Name + Domain Root', value: 'fuzzyNameDomainRoot' },
    { label: 'Manual', value: 'manual' },
    { label: 'All scenarios', value: '' }
];

const CUSTOMER_MODE_OPTIONS = [
    { label: 'No customers in group (safe auto-merge)', value: 'noCustomers' },
    { label: 'Single customer (customer becomes master)', value: 'singleCustomer' }
];

const STATUS_META = {
    Resolved:    { label: 'Resolved',     cls: 'bulk-pill bulk-pill--resolved' },
    Failed:      { label: 'Failed',       cls: 'bulk-pill bulk-pill--failed' },
    NeedsReview: { label: 'Needs review', cls: 'bulk-pill bulk-pill--needsreview' },
    Queued:      { label: 'Queued',       cls: 'bulk-pill bulk-pill--queued' },
    Processing:  { label: 'Processing',   cls: 'bulk-pill bulk-pill--processing' }
};

export default class AccountDedupeBulkAutoMerge extends LightningElement {
    @track loading = false;
    @track queueing = false;
    @track error;
    @track scanName;
    @track totalOpenGroups = 0;
    @track eligibleCount = 0;
    @track candidates = [];
    @track masterByGroup = {};
    @track skippedByGroup = {};
    @track scenarioFilter = 'exactWebsite';
    @track customerMode = 'noCustomers';

    @track recentResults = [];
    @track recentLoading = false;
    _scanId = null;
    _pollTimer = null;

    scenarioFilterOptions = SCENARIO_FILTER_OPTIONS;
    customerModeOptions = CUSTOMER_MODE_OPTIONS;

    connectedCallback() {
        this.load();
    }

    disconnectedCallback() {
        this._stopPolling();
    }

    handleScenarioFilterChange(event) {
        this.scenarioFilter = event.detail.value;
        this.load();
    }

    handleCustomerModeChange(event) {
        this.customerMode = event.detail.value;
        this.load();
    }

    async load() {
        this.loading = true;
        this.error = undefined;
        try {
            const res = await getBulkMergeCandidates({
                scanId: null,
                scenarioFilter: this.scenarioFilter || null,
                customerMode: this.customerMode,
                maxResults: 100
            });
            this._scanId = res.scanId || null;
            this.scanName = res.scanName;
            this.totalOpenGroups = res.totalOpenGroups || 0;
            this.eligibleCount = res.eligibleCount || 0;
            this.candidates = res.candidates || [];
            const masters = {};
            const skipped = {};
            for (const c of this.candidates) {
                masters[c.groupId] = c.suggestedMasterId;
                skipped[c.groupId] = false;
            }
            this.masterByGroup = masters;
            this.skippedByGroup = skipped;
        } catch (e) {
            this.error = this.extractError(e);
        } finally {
            this.loading = false;
        }
        await this.loadRecent();
    }

    async loadRecent() {
        this.recentLoading = true;
        try {
            const rows = await getRecentlyProcessed({ scanId: this._scanId, maxResults: 100 });
            this.recentResults = rows || [];
        } catch (e) {
            // non-critical — don't surface as main error
        } finally {
            this.recentLoading = false;
        }
    }

    _startPolling() {
        this._stopPolling();
        this._pollTimer = setInterval(async () => {
            await this.loadRecent();
            if (!this._hasPendingRecent) this._stopPolling();
        }, 5000);
    }

    _stopPolling() {
        if (this._pollTimer != null) {
            clearInterval(this._pollTimer);
            this._pollTimer = null;
        }
    }

    handlePickMaster(event) {
        const groupId = event.currentTarget.dataset.group;
        const accountId = event.currentTarget.dataset.account;
        this.masterByGroup = { ...this.masterByGroup, [groupId]: accountId };
    }

    handleToggleSkip(event) {
        const groupId = event.currentTarget.dataset.group;
        this.skippedByGroup = { ...this.skippedByGroup, [groupId]: event.target.checked };
    }

    handleRefresh() {
        this.load();
    }

    handleRefreshRecent() {
        this.loadRecent();
    }

    async handleQueueAll() {
        const requests = [];
        for (const c of this.candidates) {
            if (this.skippedByGroup[c.groupId]) continue;
            const masterId = this.masterByGroup[c.groupId];
            if (!masterId) continue;
            requests.push({ groupId: c.groupId, masterId, notes: 'Bulk auto-merge' });
        }
        if (!requests.length) {
            this.toast('Nothing to queue', 'Pick at least one group.', 'warning');
            return;
        }
        // eslint-disable-next-line no-alert
        const ok = window.confirm(
            `Queue ${requests.length} group${requests.length === 1 ? '' : 's'} for unattended auto-merge?\n\n` +
            `Each group will clean up duplicate contact relations, then merge using the picked master ` +
            `with the "master wins, fill nulls from duplicates" policy.`
        );
        if (!ok) return;
        this.queueing = true;
        // eslint-disable-next-line no-console
        console.log('[BulkMerge] queueGroupsForMerge requests:', JSON.stringify(requests.slice(0, 5)));
        // Strip LWC reactive-membrane proxy wrapping before sending to Apex.
        // Without this, @track-derived Id values appear as null on the Apex side.
        const plainRequests = JSON.parse(JSON.stringify(requests));
        try {
            const n = await queueGroupsForMerge({ requests: plainRequests });
            if (n > 0) {
                this.toast(
                    `Queued ${n} group${n === 1 ? '' : 's'}`,
                    'Status updates appear below as the drainer runs.',
                    'success'
                );
                await this.load();
                this._startPolling();
            } else {
                this.toast(
                    'Nothing queued',
                    'All groups were skipped — master account could not be resolved. Check the console for details.',
                    'warning'
                );
            }
        } catch (e) {
            this.toast('Bulk queue failed', this.extractError(e), 'error');
        } finally {
            this.queueing = false;
        }
    }

    get hasCandidates() {
        return this.candidates && this.candidates.length > 0;
    }

    get hasRecentResults() {
        return this.recentResults && this.recentResults.length > 0;
    }

    get _hasPendingRecent() {
        return this.recentResults.some(r => r.status === 'Queued' || r.status === 'Processing');
    }

    get hasPendingRecent() {
        return this._hasPendingRecent;
    }

    get headlineLabel() {
        if (!this.scanName) return 'No completed scan yet — run one first.';
        return `Scan ${this.scanName} · ${this.eligibleCount} eligible of ${this.totalOpenGroups} open`;
    }

    get queueButtonLabel() {
        const n = this.activeCount;
        return `Queue ${n} group${n === 1 ? '' : 's'} for auto-merge`;
    }

    get queueButtonDisabled() {
        return this.queueing || this.activeCount === 0;
    }

    get activeCount() {
        let n = 0;
        for (const c of this.candidates) {
            if (this.skippedByGroup[c.groupId]) continue;
            if (this.masterByGroup[c.groupId]) n += 1;
        }
        return n;
    }

    get recentSummary() {
        const counts = {};
        for (const r of this.recentResults) {
            counts[r.status] = (counts[r.status] || 0) + 1;
        }
        const parts = [];
        if (counts.Resolved)    parts.push(`${counts.Resolved} resolved`);
        if (counts.Failed)      parts.push(`${counts.Failed} failed`);
        if (counts.NeedsReview) parts.push(`${counts.NeedsReview} needs review`);
        if (counts.Queued)      parts.push(`${counts.Queued} queued`);
        if (counts.Processing)  parts.push(`${counts.Processing} processing`);
        return parts.join(' · ');
    }

    get recentRows() {
        return this.recentResults.map((r) => {
            const meta = STATUS_META[r.status] || { label: r.status, cls: 'bulk-pill' };
            return {
                ...r,
                statusLabel: meta.label,
                statusClass: meta.cls,
                lastModifiedDisplay: r.lastModifiedDate
                    ? new Date(r.lastModifiedDate).toLocaleString()
                    : '—',
                displayError: r.errorMessage || ''
            };
        });
    }

    get candidateRows() {
        return this.candidates.map((c) => {
            const masterId = this.masterByGroup[c.groupId];
            const skipped = !!this.skippedByGroup[c.groupId];
            return {
                ...c,
                skipped,
                cardClass: skipped ? 'bulk-card bulk-card--skipped' : 'bulk-card',
                members: (c.members || []).map((m) => ({
                    ...m,
                    isMaster: m.accountId === masterId,
                    isSuggested: m.accountId === c.suggestedMasterId,
                    radioId: `bulk-${c.groupId}-${m.accountId}`,
                    radioName: `bulk-${c.groupId}`,
                    rowClass: m.accountId === masterId ? 'bulk-row bulk-row--master' : 'bulk-row',
                    displayStatus: m.accountStatus || '—',
                    statusClass: m.isCustomer ? 'bulk-status bulk-status--customer' : 'bulk-status',
                    displayOwner: m.ownerName || '—',
                    displayActivity: m.lastActivityDate || (m.lastModifiedDate ? new Date(m.lastModifiedDate).toISOString().slice(0, 10) + ' (modified)' : '—')
                }))
            };
        });
    }

    extractError(e) {
        if (!e) return 'Unknown error';
        if (typeof e === 'string') return e;
        if (e.body && e.body.message) return e.body.message;
        if (e.message) return e.message;
        return JSON.stringify(e);
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
