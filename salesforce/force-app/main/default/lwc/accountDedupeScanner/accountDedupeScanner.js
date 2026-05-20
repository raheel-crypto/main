import { LightningElement, track, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { NavigationMixin } from 'lightning/navigation';
import listScenarios from '@salesforce/apex/AccountDedupeScanController.listScenarios';
import startScan from '@salesforce/apex/AccountDedupeScanController.startScan';
import listScans from '@salesforce/apex/AccountDedupeScanController.listScans';
import listGroups from '@salesforce/apex/AccountDedupeScanController.listGroups';

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
    @track statusFilter = 'Open';
    @track scenarioFilter = '';
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
        this.expandedGroupId = undefined;
        this.refreshGroups();
    }

    handleStatusFilterChange(event) {
        this.statusFilter = event.detail.value;
        this.refreshGroups();
    }

    handleScenarioFilterChange(event) {
        this.scenarioFilter = event.detail.value || '';
        this.refreshGroups();
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
        this.expandedGroupId = this.expandedGroupId === id ? undefined : id;
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
    get hasGroups() { return this.groups && this.groups.length > 0; }

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
        return this.groups.map((g) => ({
            ...g,
            expanded: g.id === this.expandedGroupId,
            chevron: g.id === this.expandedGroupId ? 'utility:chevrondown' : 'utility:chevronright',
            statusVariant: g.status === 'Resolved' ? 'success' : 'warning'
        }));
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
