import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { NavigationMixin } from 'lightning/navigation';
import findDuplicates from '@salesforce/apex/AccountDedupeController.findDuplicates';

export default class AccountDuplicateFinder extends NavigationMixin(LightningElement) {
    @api recordId;

    @track loading = false;
    @track error;
    @track data;

    @track activeScenarioKey;
    @track selectedDupeIds = new Set();
    @track compareMode = false;

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
            this.selectedDupeIds = new Set();
            this.compareMode = false;
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

    get compareAccountIds() {
        return [this.recordId, ...Array.from(this.selectedDupeIds).filter((id) => id !== this.recordId)];
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
        this.compareMode = true;
    }

    handleCancelCompare() {
        this.compareMode = false;
    }

    async handleMergeComplete(event) {
        const masterId = event.detail && event.detail.masterId;
        this.compareMode = false;
        if (masterId && masterId !== this.recordId) {
            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: { recordId: masterId, objectApiName: 'Account', actionName: 'view' }
            });
        } else {
            await this.load();
        }
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
