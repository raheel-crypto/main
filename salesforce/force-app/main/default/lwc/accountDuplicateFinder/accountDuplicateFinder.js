import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { NavigationMixin } from 'lightning/navigation';
import findDuplicates from '@salesforce/apex/AccountDedupeController.findDuplicates';
import mergeAccounts from '@salesforce/apex/AccountDedupeController.mergeAccounts';

export default class AccountDuplicateFinder extends NavigationMixin(LightningElement) {
    @api recordId;

    @track loading = false;
    @track merging = false;
    @track error;
    @track data;

    @track activeScenarioKey;
    @track selectedDupeIds = new Set();
    @track masterId;
    @track compareMode = false;
    @track fieldChoices = {};

    connectedCallback() {
        this.load();
    }

    @api
    refresh() {
        this.load();
    }

    async load() {
        this.loading = true;
        this.error = undefined;
        try {
            const result = await findDuplicates({ recordId: this.recordId });
            this.data = result;
            this.masterId = this.recordId;
            this.selectedDupeIds = new Set();
            this.compareMode = false;
            this.fieldChoices = {};
            if (result.scenarios && result.scenarios.length) {
                const firstNonEmpty = result.scenarios.find((s) => s.matchIds && s.matchIds.length);
                this.activeScenarioKey = (firstNonEmpty || result.scenarios[0]).key;
            }
        } catch (e) {
            this.error = this.extractError(e);
        } finally {
            this.loading = false;
        }
    }

    get scenarioTabs() {
        if (!this.data) return [];
        return this.data.scenarios.map((s) => ({
            key: s.key,
            label: s.label,
            description: s.description,
            count: s.matchIds.length,
            active: s.key === this.activeScenarioKey,
            badgeVariant: s.matchIds.length > 0 ? 'warning' : 'inverse',
            buttonVariant: s.key === this.activeScenarioKey ? 'brand' : 'neutral'
        }));
    }

    get activeScenario() {
        if (!this.data) return null;
        return this.data.scenarios.find((s) => s.key === this.activeScenarioKey);
    }

    get activeMatchRows() {
        const scenario = this.activeScenario;
        if (!scenario) return [];
        return scenario.matchIds.map((id) => {
            const rec = this.data.records[id] || {};
            return {
                id,
                name: rec.Name || '(no name)',
                website: rec.Website,
                linkedin: rec.LinkedIn_URL__c,
                domain: rec.Normalized_Domain__c,
                domainRoot: rec.Domain_Root__c,
                ownerName: rec.OwnerName,
                lastModified: rec.LastModifiedDate,
                selected: this.selectedDupeIds.has(id),
                checkboxLabel: `Select ${rec.Name || id}`
            };
        });
    }

    get hasActiveMatches() {
        return this.activeMatchRows.length > 0;
    }

    get selectedCount() {
        return this.selectedDupeIds.size;
    }

    get compareDisabled() {
        return this.selectedCount === 0;
    }

    get mergeButtonLabel() {
        const n = this.selectedCount;
        return n > 0 ? `Compare & Merge (${n})` : 'Compare & Merge';
    }

    get participantIds() {
        const ids = [this.masterId, ...Array.from(this.selectedDupeIds).filter((id) => id !== this.masterId)];
        return Array.from(new Set(ids));
    }

    get compareColumns() {
        if (!this.data) return [];
        return this.participantIds.map((id) => {
            const rec = this.data.records[id] || {};
            return {
                id,
                name: rec.Name || '(unknown)',
                isMaster: id === this.masterId,
                radioName: `master`,
                radioId: `master-${id}`,
                masterVariant: id === this.masterId ? 'brand' : 'neutral',
                masterLabel: id === this.masterId ? 'Master' : 'Make Master'
            };
        });
    }

    get compareRows() {
        if (!this.data || !this.compareMode) return [];
        return this.data.fields.map((field) => {
            const chosenId = this.fieldChoices[field.apiName] || this.masterId;
            const cells = this.participantIds.map((id) => {
                const rec = this.data.records[id] || {};
                const value = this.formatValue(rec[field.apiName], field.type);
                return {
                    id,
                    fieldName: field.apiName,
                    value,
                    radioId: `${field.apiName}-${id}`,
                    checked: chosenId === id,
                    radioGroup: `radio-${field.apiName}`,
                    canSelect: field.updateable,
                    cellClass: chosenId === id ? 'slds-cell-buffer_small slds-theme_shade' : 'slds-cell-buffer_small'
                };
            });
            return {
                key: field.apiName,
                label: field.label,
                apiName: field.apiName,
                updateable: field.updateable,
                cells
            };
        });
    }

    handleScenarioClick(event) {
        this.activeScenarioKey = event.currentTarget.dataset.key;
    }

    handleSelectToggle(event) {
        const id = event.currentTarget.dataset.id;
        const checked = event.target.checked;
        const next = new Set(this.selectedDupeIds);
        if (checked) next.add(id);
        else next.delete(id);
        this.selectedDupeIds = next;
    }

    handleOpenRecord(event) {
        const id = event.currentTarget.dataset.id;
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: id, objectApiName: 'Account', actionName: 'view' }
        });
    }

    handleCompare() {
        if (!this.selectedDupeIds.size) return;
        this.fieldChoices = {};
        this.compareMode = true;
    }

    handleCancelCompare() {
        this.compareMode = false;
        this.fieldChoices = {};
    }

    handlePickMaster(event) {
        const id = event.currentTarget.dataset.id;
        if (id === this.masterId) return;
        const next = new Set(this.selectedDupeIds);
        next.delete(id);
        next.add(this.masterId);
        this.selectedDupeIds = next;
        this.masterId = id;
        this.fieldChoices = {};
    }

    handleFieldChoice(event) {
        const field = event.currentTarget.dataset.field;
        const id = event.currentTarget.dataset.id;
        this.fieldChoices = { ...this.fieldChoices, [field]: id };
    }

    async handleConfirmMerge() {
        const dupeIds = this.participantIds.filter((id) => id !== this.masterId);
        if (!dupeIds.length) {
            this.toast('Nothing to merge', 'Select at least one duplicate.', 'warning');
            return;
        }
        const fieldSourceMap = {};
        for (const [field, sourceId] of Object.entries(this.fieldChoices)) {
            if (sourceId && sourceId !== this.masterId) {
                fieldSourceMap[field] = sourceId;
            }
        }
        this.merging = true;
        try {
            await mergeAccounts({
                masterId: this.masterId,
                duplicateIds: dupeIds,
                fieldSourceMap
            });
            this.toast('Merged', `${dupeIds.length} record(s) merged into master.`, 'success');
            if (this.masterId !== this.recordId) {
                this[NavigationMixin.Navigate]({
                    type: 'standard__recordPage',
                    attributes: { recordId: this.masterId, objectApiName: 'Account', actionName: 'view' }
                });
            } else {
                await this.load();
            }
        } catch (e) {
            this.toast('Merge failed', this.extractError(e), 'error');
        } finally {
            this.merging = false;
        }
    }

    formatValue(value, type) {
        if (value === null || value === undefined || value === '') return '—';
        if (type === 'CURRENCY' || type === 'DOUBLE' || type === 'INTEGER') {
            try {
                return Number(value).toLocaleString();
            } catch (e) {
                return String(value);
            }
        }
        if (type === 'DATETIME' || type === 'DATE') {
            try {
                return new Date(value).toLocaleString();
            } catch (e) {
                return String(value);
            }
        }
        return String(value);
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
