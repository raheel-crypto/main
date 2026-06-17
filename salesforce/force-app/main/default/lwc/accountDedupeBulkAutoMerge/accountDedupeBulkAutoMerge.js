import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getBulkMergeCandidates from '@salesforce/apex/AccountDedupeScanController.getBulkMergeCandidates';
import queueGroupsForMerge from '@salesforce/apex/AccountDedupeScanController.queueGroupsForMerge';

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

    connectedCallback() {
        this.load();
    }

    async load() {
        this.loading = true;
        this.error = undefined;
        try {
            const res = await getBulkMergeCandidates({ scanId: null, maxResults: 100 });
            this.scanName = res.scanName;
            this.totalOpenGroups = res.totalOpenGroups || 0;
            this.eligibleCount = res.eligibleCount || 0;
            this.candidates = res.candidates || [];
            // Seed master picks with the suggested master for every candidate.
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
        try {
            const n = await queueGroupsForMerge({ requests });
            this.toast(
                `Queued ${n} group${n === 1 ? '' : 's'}`,
                'Watch the scanner for status. The drainer runs in the background.',
                'success'
            );
            await this.load();
        } catch (e) {
            this.toast('Bulk queue failed', this.extractError(e), 'error');
        } finally {
            this.queueing = false;
        }
    }

    get hasCandidates() {
        return this.candidates && this.candidates.length > 0;
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
                    displayType: m.accountType || '—',
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
