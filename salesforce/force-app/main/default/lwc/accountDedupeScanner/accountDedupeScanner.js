import { LightningElement, track, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { NavigationMixin } from 'lightning/navigation';
import listScenarios from '@salesforce/apex/AccountDedupeScanController.listScenarios';
import startScan from '@salesforce/apex/AccountDedupeScanController.startScan';
import listScans from '@salesforce/apex/AccountDedupeScanController.listScans';
import listGroups from '@salesforce/apex/AccountDedupeScanController.listGroups';
import listAcrConflicts from '@salesforce/apex/AccountDedupeScanController.listAcrConflicts';
import cleanupAcrConflicts from '@salesforce/apex/AccountDedupeScanController.cleanupAcrConflicts';

const POLL_INTERVAL_MS = 4000;
const STATUS_FILTER_OPTIONS = [
    { label: 'Open', value: 'Open' },
    { label: 'Resolved', value: 'Resolved' },
    { label: 'All', value: '' }
];

export default class AccountDedupeScanner extends NavigationMixin(LightningElement) {
    @track scenarioOptions = [];
    @track selectedScenarios = new Set();
    @track scans = [];
    @track activeScanId;
    @track groups = [];
    @track expandedGroupId;
    @track expandedMasterId;
    @track expandedAcrConflicts = [];
    @track expandedAcrLoading = false;
    @track expandedAcrCleaning = false;
    @track statusFilter = 'Open';
    @track scenarioFilter = '';
    @track searchQuery = '';
    @track starting = false;
    @track loadingGroups = false;
    @track error;

    statusFilterOptions = STATUS_FILTER_OPTIONS;
    pollHandle;

    @wire(listScenarios)
    wiredScenarios({ data, error }) {
        if (data) {
            this.scenarioOptions = data.map((o) => ({ ...o, checked: true }));
            this.selectedScenarios = new Set(data.map((o) => o.key));
        } else if (error) {
            this.error = this.extractError(error);
        }
    }

    connectedCallback() {
        this.refreshScans();
    }

    disconnectedCallback() {
        this.stopPolling();
    }

    async refreshScans() {
        try {
            this.scans = await listScans({ maxResults: 20 });
            if (!this.activeScanId && this.scans.length) {
                this.activeScanId = this.scans[0].id;
                this.refreshGroups();
            }
            const anyRunning = this.scans.some((s) => s.status === 'Running');
            if (anyRunning) this.startPolling();
            else this.stopPolling();
        } catch (e) {
            this.error = this.extractError(e);
        }
    }

    startPolling() {
        if (this.pollHandle) return;
        this.pollHandle = setInterval(() => this.refreshScans(), POLL_INTERVAL_MS);
    }

    stopPolling() {
        if (this.pollHandle) {
            clearInterval(this.pollHandle);
            this.pollHandle = undefined;
        }
    }

    handleScenarioToggle(event) {
        const key = event.currentTarget.dataset.key;
        const next = new Set(this.selectedScenarios);
        if (event.target.checked) next.add(key);
        else next.delete(key);
        this.selectedScenarios = next;
        this.scenarioOptions = this.scenarioOptions.map((o) =>
            o.key === key ? { ...o, checked: event.target.checked } : o
        );
    }

    get runDisabled() {
        return this.starting || this.selectedScenarios.size === 0;
    }

    async handleRunScan() {
        if (this.runDisabled) return;
        this.starting = true;
        try {
            const scanId = await startScan({ scenarioKeys: Array.from(this.selectedScenarios) });
            this.activeScanId = scanId;
            this.toast('Scan started', 'Results will appear here as it runs.', 'success');
            await this.refreshScans();
            this.startPolling();
        } catch (e) {
            this.toast('Could not start scan', this.extractError(e), 'error');
        } finally {
            this.starting = false;
        }
    }

    handleScanClick(event) {
        const id = event.currentTarget.dataset.id;
        if (id === this.activeScanId) return;
        this.activeScanId = id;
        this.resetExpansion();
        this.refreshGroups();
    }

    handleStatusFilterChange(event) {
        this.statusFilter = event.detail.value;
        this.resetExpansion();
        this.refreshGroups();
    }

    handleScenarioFilterChange(event) {
        this.scenarioFilter = event.detail.value || '';
        this.resetExpansion();
        this.refreshGroups();
    }

    handleSearchChange(event) {
        this.searchQuery = (event.target.value || '').trim().toLowerCase();
    }

    async refreshGroups() {
        if (!this.activeScanId) return;
        this.loadingGroups = true;
        try {
            this.groups = await listGroups({
                scanId: this.activeScanId,
                statusFilter: this.statusFilter || null,
                scenarioFilter: this.scenarioFilter || null
            });
        } catch (e) {
            this.error = this.extractError(e);
        } finally {
            this.loadingGroups = false;
        }
    }

    handleGroupClick(event) {
        const id = event.currentTarget.dataset.id;
        if (this.expandedGroupId === id) {
            this.resetExpansion();
        } else {
            this.expandedGroupId = id;
            this.expandedMasterId = undefined;
            this.expandedAcrConflicts = [];
            this.loadAcrConflicts();
        }
    }

    resetExpansion() {
        this.expandedGroupId = undefined;
        this.expandedMasterId = undefined;
        this.expandedAcrConflicts = [];
        this.expandedAcrLoading = false;
        this.expandedAcrCleaning = false;
    }

    handleMasterPick(event) {
        event.stopPropagation();
        this.expandedMasterId = event.currentTarget.dataset.id;
    }

    async loadAcrConflicts() {
        if (!this.expandedGroupId) {
            this.expandedAcrConflicts = [];
            return;
        }
        this.expandedAcrLoading = true;
        try {
            const data = await listAcrConflicts({ groupId: this.expandedGroupId });
            this.expandedAcrConflicts = data || [];
        } catch (e) {
            this.expandedAcrConflicts = [];
        } finally {
            this.expandedAcrLoading = false;
        }
    }

    async handleCleanupAcrs() {
        if (this.cleanupDisabled) return;
        this.expandedAcrCleaning = true;
        try {
            const count = await cleanupAcrConflicts({
                groupId: this.expandedGroupId,
                masterAccountId: this.expandedMasterId
            });
            this.toast(
                `Cleaned up ${count} relation${count === 1 ? '' : 's'}`,
                'You can now merge into the master record.',
                'success'
            );
            await this.loadAcrConflicts();
        } catch (e) {
            this.toast('Cleanup failed', this.extractError(e), 'error');
        } finally {
            this.expandedAcrCleaning = false;
        }
    }

    handleOpenAccount(event) {
        event.stopPropagation();
        const id = event.currentTarget.dataset.id;
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: id, objectApiName: 'Account', actionName: 'view' }
        });
    }

    get hasScans() { return this.scans && this.scans.length > 0; }

    get filteredGroups() {
        if (!this.searchQuery) return this.groups;
        const q = this.searchQuery;
        return this.groups.filter((g) =>
            (g.matchKey || '').toLowerCase().includes(q) ||
            (g.name || '').toLowerCase().includes(q) ||
            (g.scenarioLabel || '').toLowerCase().includes(q)
        );
    }

    get hasFilteredGroups() {
        return this.filteredGroups.length > 0;
    }

    get emptyMessage() {
        if (!this.activeScanId) return 'Run a scan to see duplicate groups.';
        if (this.searchQuery) return `No groups match "${this.searchQuery}".`;
        return 'No groups for the selected filters.';
    }

    get scenarioFilterOptions() {
        return [{ label: 'All scenarios', value: '' }]
            .concat(this.scenarioOptions.map((o) => ({ label: o.label, value: o.key })));
    }

    get scanRows() {
        return this.scans.map((s) => ({
            ...s,
            active: s.id === this.activeScanId,
            rowClass: s.id === this.activeScanId
                ? 'slds-item slds-theme_shade slds-p-around_small slds-border_bottom'
                : 'slds-item slds-p-around_small slds-border_bottom',
            statusVariant: s.status === 'Running' ? 'warning'
                : s.status === 'Failed' ? 'error'
                : 'success'
        }));
    }

    get groupRows() {
        const masterId = this.expandedMasterId;
        return this.filteredGroups.map((g) => {
            const expanded = g.id === this.expandedGroupId;
            return {
                ...g,
                expanded,
                chevron: expanded ? 'utility:chevrondown' : 'utility:chevronright',
                statusVariant: g.status === 'Resolved' ? 'success' : 'warning',
                displayMatchKey: g.matchKey || '(no key)',
                metaLine: `${g.memberCount} accounts · ${g.scenarioLabel} · ${g.name}`,
                members: (g.members || []).map((m) => ({
                    ...m,
                    isMaster: expanded && m.accountId === masterId,
                    radioId: `master-${g.id}-${m.accountId}`,
                    radioName: `master-${g.id}`,
                    rowClass: expanded && m.accountId === masterId
                        ? 'master-row'
                        : ''
                }))
            };
        });
    }

    get acrConflictRows() {
        const masterId = this.expandedMasterId;
        return this.expandedAcrConflicts.map((c) => ({
            key: c.contactId,
            contactId: c.contactId,
            contactName: c.contactName || '(no name)',
            contactTitle: c.contactTitle || '',
            contactEmail: c.contactEmail || '',
            relations: (c.relations || []).map((r) => ({
                key: r.relationId,
                accountId: r.accountId,
                label: r.accountName + (r.isDirect ? ' • primary' : ''),
                cellClass: r.accountId === masterId
                    ? 'acr-rel acr-rel--master'
                    : 'acr-rel'
            }))
        }));
    }

    get hasAcrConflicts() {
        return this.expandedAcrConflicts && this.expandedAcrConflicts.length > 0;
    }

    get acrConflictsLabel() {
        const n = this.expandedAcrConflicts ? this.expandedAcrConflicts.length : 0;
        return `${n} contact${n === 1 ? '' : 's'} linked to multiple accounts in this group`;
    }

    get cleanupDisabled() {
        return !this.expandedMasterId || this.expandedAcrCleaning || !this.hasAcrConflicts;
    }

    get cleanupButtonLabel() {
        return this.expandedMasterId ? 'Clean up duplicate relations' : 'Pick a master first';
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
