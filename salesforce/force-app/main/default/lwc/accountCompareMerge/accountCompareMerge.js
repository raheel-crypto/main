import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getCompareData from '@salesforce/apex/AccountDedupeController.getCompareData';
import mergeAccounts from '@salesforce/apex/AccountDedupeController.mergeAccounts';

export default class AccountCompareMerge extends LightningElement {
    _accountIds = [];
    @api get accountIds() { return this._accountIds; }
    set accountIds(v) {
        this._accountIds = Array.isArray(v) ? [...v] : [];
        if (this.isConnected) this.load();
    }

    @api initialMasterId;

    @track loading = false;
    @track merging = false;
    @track error;
    @track data;
    @track masterId;
    @track fieldChoices = {};

    isConnected = false;

    connectedCallback() {
        this.isConnected = true;
        if (this._accountIds.length) this.load();
    }

    async load() {
        if (!this._accountIds.length) return;
        this.loading = true;
        this.error = undefined;
        try {
            this.data = await getCompareData({ accountIds: this._accountIds });
            this.masterId = this.initialMasterId && this._accountIds.includes(this.initialMasterId)
                ? this.initialMasterId
                : this._accountIds[0];
            this.fieldChoices = {};
        } catch (e) {
            this.error = this.extractError(e);
        } finally {
            this.loading = false;
        }
    }

    get participantIds() {
        return [this.masterId, ...this._accountIds.filter((id) => id !== this.masterId)];
    }

    get compareColumns() {
        if (!this.data) return [];
        return this.participantIds.map((id) => {
            const rec = this.data.records[id] || {};
            return {
                id,
                name: rec.Name || '(unknown)',
                isMaster: id === this.masterId,
                masterVariant: id === this.masterId ? 'brand' : 'neutral',
                masterLabel: id === this.masterId ? 'Master' : 'Make Master'
            };
        });
    }

    get compareRows() {
        if (!this.data) return [];
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

    get mergePreviewLabel() {
        const n = Math.max(0, this._accountIds.length - 1);
        const calls = n > 0 ? Math.ceil(n / 2) : 0;
        return `Will merge ${n} record${n === 1 ? '' : 's'} into the master (${calls} merge call${calls === 1 ? '' : 's'}).`;
    }

    handlePickMaster(event) {
        const id = event.currentTarget.dataset.id;
        if (id === this.masterId) return;
        this.masterId = id;
        this.fieldChoices = {};
    }

    handleFieldChoice(event) {
        const field = event.currentTarget.dataset.field;
        const id = event.currentTarget.dataset.id;
        this.fieldChoices = { ...this.fieldChoices, [field]: id };
    }

    handleCancel() {
        this.dispatchEvent(new CustomEvent('cancel'));
    }

    async handleConfirm() {
        const dupeIds = this._accountIds.filter((id) => id !== this.masterId);
        if (!dupeIds.length) {
            this.toast('Nothing to merge', 'Need at least one duplicate.', 'warning');
            return;
        }
        const fieldSourceMap = {};
        for (const [field, sourceId] of Object.entries(this.fieldChoices)) {
            if (sourceId && sourceId !== this.masterId) fieldSourceMap[field] = sourceId;
        }
        this.merging = true;
        try {
            await mergeAccounts({
                masterId: this.masterId,
                duplicateIds: dupeIds,
                fieldSourceMap
            });
            this.toast('Merged', `${dupeIds.length} record(s) merged into master.`, 'success');
            this.dispatchEvent(new CustomEvent('mergecomplete', {
                detail: { masterId: this.masterId, mergedCount: dupeIds.length }
            }));
        } catch (e) {
            this.toast('Merge failed', this.extractError(e), 'error');
        } finally {
            this.merging = false;
        }
    }

    formatValue(value, type) {
        if (value === null || value === undefined || value === '') return '—';
        if (type === 'CURRENCY' || type === 'DOUBLE' || type === 'INTEGER') {
            try { return Number(value).toLocaleString(); } catch (e) { return String(value); }
        }
        if (type === 'DATETIME' || type === 'DATE') {
            try { return new Date(value).toLocaleString(); } catch (e) { return String(value); }
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
