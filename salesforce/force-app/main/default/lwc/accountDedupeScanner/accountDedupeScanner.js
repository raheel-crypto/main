import { LightningElement, track, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { NavigationMixin } from 'lightning/navigation';
import listScenarios from '@salesforce/apex/AccountDedupeScanController.listScenarios';
import startScan from '@salesforce/apex/AccountDedupeScanController.startScan';
import listScans from '@salesforce/apex/AccountDedupeScanController.listScans';
import listGroups from '@salesforce/apex/AccountDedupeScanController.listGroups';
import listAcrConflicts from '@salesforce/apex/AccountDedupeScanController.listAcrConflicts';
import cleanupAcrConflicts from '@salesforce/apex/AccountDedupeScanController.cleanupAcrConflicts';
import dismissGroups from '@salesforce/apex/AccountDedupeScanController.dismissGroups';
import createManualGroup from '@salesforce/apex/AccountDedupeScanController.createManualGroup';
import getAccountSummaries from '@salesforce/apex/AccountDedupeScanController.getAccountSummaries';

const POLL_INTERVAL_MS = 4000;
const STATUS_FILTER_OPTIONS = [
    { label: 'Open', value: 'Open' },
    { label: 'Resolved', value: 'Resolved' },
    { label: 'All', value: '' }
];
const SORT_OPTIONS = [
    { label: 'Largest first', value: 'largestFirst' },
    { label: 'Smallest first', value: 'smallestFirst' },
    { label: 'Scenario A→Z', value: 'scenarioAsc' },
    { label: 'Match key A→Z', value: 'keyAsc' }
];
const SCENARIO_CLASS = {
    exactWebsite: 'scenario-chip scenario-chip--blue',
    exactLinkedIn: 'scenario-chip scenario-chip--indigo',
    nameNormalizedDomain: 'scenario-chip scenario-chip--teal',
    nameDomainRoot: 'scenario-chip scenario-chip--green',
    fuzzyNameDomainRoot: 'scenario-chip scenario-chip--orange',
    manual: 'scenario-chip scenario-chip--purple'
};
const MANUAL_MAX = 5;

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
    @track expandedMergeMode = false;
    @track selectedGroupIds = new Set();
    @track statusFilter = 'Open';
    @track scenarioFilter = '';
    @track searchQuery = '';
    @track sortBy = 'largestFirst';
    @track starting = false;
    @track loadingGroups = false;
    @track dismissingBulk = false;
    @track error;

    // Manual-group panel state
    @track manualPanelOpen = false;
    @track manualMatchKey = '';
    @track manualSelected = [];
    @track manualSubmitting = false;
    pickerNonce = 0;

    statusFilterOptions = STATUS_FILTER_OPTIONS;
    sortOptions = SORT_OPTIONS;
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
        this.selectedGroupIds = new Set();
        this.refreshGroups();
    }

    handleStatusFilterChange(event) {
        this.statusFilter = event.detail.value;
        this.resetExpansion();
        this.selectedGroupIds = new Set();
        this.refreshGroups();
    }

    handleScenarioFilterChange(event) {
        this.scenarioFilter = event.detail.value || '';
        this.resetExpansion();
        this.selectedGroupIds = new Set();
        this.refreshGroups();
    }

    handleSearchChange(event) {
        this.searchQuery = (event.target.value || '').trim().toLowerCase();
    }

    handleSortChange(event) {
        this.sortBy = event.detail.value;
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
        this.expandedMergeMode = false;
    }

    handleStartMerge() {
        if (!this.expandedMasterId) return;
        this.expandedMergeMode = true;
    }

    handleMergeCancel() {
        this.expandedMergeMode = false;
    }

    async handleMergeComplete() {
        this.expandedMergeMode = false;
        // The merge service marks the group Resolved automatically;
        // refresh so the row drops out of the Open filter.
        await this.refreshGroups();
        this.resetExpansion();
    }

    handleMasterPick(event) {
        event.stopPropagation();
        this.expandedMasterId = event.currentTarget.dataset.id;
    }

    handleGroupSelect(event) {
        event.stopPropagation();
        const id = event.currentTarget.dataset.id;
        const next = new Set(this.selectedGroupIds);
        if (event.target.checked) next.add(id);
        else next.delete(id);
        this.selectedGroupIds = next;
    }

    handleSelectAll(event) {
        const checked = event.target.checked;
        if (checked) {
            this.selectedGroupIds = new Set(this.filteredGroups.map((g) => g.id));
        } else {
            this.selectedGroupIds = new Set();
        }
    }

    async handleDismissGroup(event) {
        event.stopPropagation();
        const id = event.currentTarget.dataset.id;
        if (!id) return;
        // eslint-disable-next-line no-alert
        if (!window.confirm('Mark this group as Not a duplicate? It will move to Resolved without merging.')) return;
        try {
            await dismissGroups({ groupIds: [id] });
            this.toast('Group dismissed', 'Moved to Resolved.', 'success');
            this.selectedGroupIds.delete(id);
            if (this.expandedGroupId === id) this.resetExpansion();
            await this.refreshGroups();
        } catch (e) {
            this.toast('Dismiss failed', this.extractError(e), 'error');
        }
    }

    async handleBulkDismiss() {
        if (this.selectedGroupIds.size === 0) return;
        const n = this.selectedGroupIds.size;
        // eslint-disable-next-line no-alert
        if (!window.confirm(`Dismiss ${n} group${n === 1 ? '' : 's'} as Not a duplicate?`)) return;
        this.dismissingBulk = true;
        try {
            const ids = Array.from(this.selectedGroupIds);
            await dismissGroups({ groupIds: ids });
            this.toast(`Dismissed ${n} group${n === 1 ? '' : 's'}`, 'Moved to Resolved.', 'success');
            this.selectedGroupIds = new Set();
            if (ids.includes(this.expandedGroupId)) this.resetExpansion();
            await this.refreshGroups();
        } catch (e) {
            this.toast('Bulk dismiss failed', this.extractError(e), 'error');
        } finally {
            this.dismissingBulk = false;
        }
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

    // ── manual group ────────────────────────────────────────────────────────

    handleToggleManualPanel() {
        this.manualPanelOpen = !this.manualPanelOpen;
        if (!this.manualPanelOpen) this.resetManualForm();
    }

    handleCancelManualPanel() {
        this.manualPanelOpen = false;
        this.resetManualForm();
    }

    resetManualForm() {
        this.manualMatchKey = '';
        this.manualSelected = [];
        this.pickerNonce += 1;
    }

    handleManualMatchKeyChange(event) {
        this.manualMatchKey = event.target.value;
    }

    async handleAccountPicked(event) {
        const recordId = event.detail && event.detail.recordId;
        if (!recordId) return;
        if (this.manualSelected.some((a) => a.accountId === recordId)) {
            this.clearRecordPicker();
            return;
        }
        if (this.manualSelected.length >= MANUAL_MAX) {
            this.toast(
                `Manual groups support up to ${MANUAL_MAX} accounts`,
                'Remove one before adding another.',
                'warning'
            );
            this.clearRecordPicker();
            return;
        }
        try {
            const existingIds = this.manualSelected.map((a) => a.accountId);
            const ids = existingIds.concat([recordId]);
            const summaries = await getAccountSummaries({ ids });
            this.manualSelected = ids
                .map((id) => summaries.find((s) => s.accountId === id))
                .filter((x) => !!x);
        } catch (e) {
            this.toast('Could not load account', this.extractError(e), 'error');
        } finally {
            this.clearRecordPicker();
        }
    }

    clearRecordPicker() {
        const picker = this.template.querySelector('lightning-record-picker');
        if (picker && typeof picker.clearSelection === 'function') {
            try { picker.clearSelection(); } catch (e) { /* ignore */ }
        } else {
            // Fallback: force re-render by bumping the key
            this.pickerNonce += 1;
        }
    }

    handleRemoveManualAccount(event) {
        const id = event.currentTarget.dataset.id;
        this.manualSelected = this.manualSelected.filter((a) => a.accountId !== id);
    }

    async handleCreateManualGroup() {
        if (this.manualSubmitting) return;
        if (this.manualSelected.length < 2) {
            this.toast('Pick at least 2 accounts', '', 'warning');
            return;
        }
        this.manualSubmitting = true;
        try {
            const ids = this.manualSelected.map((a) => a.accountId);
            await createManualGroup({
                scanId: this.activeScanId,
                accountIds: ids,
                matchKey: this.manualMatchKey || null
            });
            this.toast('Manual group created', '', 'success');
            this.resetManualForm();
            this.manualPanelOpen = false;
            // If no active scan existed, the controller created one — refresh both.
            await this.refreshScans();
            await this.refreshGroups();
        } catch (e) {
            this.toast('Could not create group', this.extractError(e), 'error');
        } finally {
            this.manualSubmitting = false;
        }
    }

    // ── derived state ───────────────────────────────────────────────────────

    get hasScans() { return this.scans && this.scans.length > 0; }

    get filteredGroups() {
        let list = this.groups;
        if (this.searchQuery) {
            const q = this.searchQuery;
            list = list.filter((g) =>
                (g.matchKey || '').toLowerCase().includes(q) ||
                (g.name || '').toLowerCase().includes(q) ||
                (g.scenarioLabel || '').toLowerCase().includes(q)
            );
        }
        const sorted = [...list];
        switch (this.sortBy) {
            case 'smallestFirst':
                sorted.sort((a, b) => (a.memberCount || 0) - (b.memberCount || 0));
                break;
            case 'scenarioAsc':
                sorted.sort((a, b) => (a.scenarioLabel || '').localeCompare(b.scenarioLabel || ''));
                break;
            case 'keyAsc':
                sorted.sort((a, b) => (a.matchKey || '').localeCompare(b.matchKey || ''));
                break;
            case 'largestFirst':
            default:
                sorted.sort((a, b) => (b.memberCount || 0) - (a.memberCount || 0));
                break;
        }
        return sorted;
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
        const selected = this.selectedGroupIds;
        return this.filteredGroups.map((g) => {
            const expanded = g.id === this.expandedGroupId;
            const isSelected = selected.has(g.id);
            const n = g.memberCount || 0;
            const merges = n > 1 ? Math.ceil((n - 1) / 2) : 0;
            return {
                ...g,
                expanded,
                selected: isSelected,
                rowClass: isSelected ? 'dedupe-group dedupe-group--selected' : 'dedupe-group',
                chevron: expanded ? 'utility:chevrondown' : 'utility:chevronright',
                statusVariant: g.status === 'Resolved' ? 'success' : 'warning',
                displayMatchKey: g.matchKey || '(no key)',
                scenarioChipClass: SCENARIO_CLASS[g.scenarioKey] || 'scenario-chip scenario-chip--grey',
                mergeLabel: `${merges} merge${merges === 1 ? '' : 's'}`,
                showMergePill: merges > 0,
                metaLine: `${n} accounts · ${g.name}`,
                members: (g.members || []).map((m) => ({
                    ...m,
                    isMaster: expanded && m.accountId === masterId,
                    radioId: `master-${g.id}-${m.accountId}`,
                    radioName: `master-${g.id}`,
                    rowClass: expanded && m.accountId === masterId ? 'master-row' : ''
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

    get mergeAccountIds() {
        const g = this.filteredGroups.find((x) => x.id === this.expandedGroupId);
        if (!g) return [];
        return (g.members || []).map((m) => m.accountId).filter(Boolean);
    }

    get mergeButtonLabel() {
        if (!this.expandedMasterId) return 'Pick a master to merge';
        const ids = this.mergeAccountIds;
        const dupes = Math.max(0, ids.length - 1);
        return `Merge ${dupes} record${dupes === 1 ? '' : 's'} into master`;
    }

    get mergeButtonDisabled() {
        return !this.expandedMasterId || this.mergeAccountIds.length < 2;
    }

    get totalGroupsCount() {
        return this.filteredGroups.length;
    }

    get totalAccountsCount() {
        return this.filteredGroups.reduce((sum, g) => sum + (g.memberCount || 0), 0);
    }

    get summaryLabel() {
        const g = this.totalGroupsCount;
        const a = this.totalAccountsCount;
        return `${g} group${g === 1 ? '' : 's'} · ${a} account${a === 1 ? '' : 's'}`;
    }

    get selectedCount() {
        return this.selectedGroupIds.size;
    }

    get hasSelection() {
        return this.selectedCount > 0;
    }

    get bulkDismissLabel() {
        const n = this.selectedCount;
        return `Dismiss ${n} selected`;
    }

    get selectAllChecked() {
        const total = this.filteredGroups.length;
        return total > 0 && this.selectedCount === total;
    }

    get manualSelectedRows() {
        return this.manualSelected.map((a) => ({
            ...a,
            displayName: a.accountName || '(no name)'
        }));
    }

    get manualCountLabel() {
        return `${this.manualSelected.length}/${MANUAL_MAX} selected`;
    }

    get manualCreateDisabled() {
        return this.manualSubmitting || this.manualSelected.length < 2;
    }

    get manualPickerDisabled() {
        return this.manualSelected.length >= MANUAL_MAX;
    }

    get manualPanelToggleLabel() {
        return this.manualPanelOpen ? 'Close' : 'Add manual group';
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
