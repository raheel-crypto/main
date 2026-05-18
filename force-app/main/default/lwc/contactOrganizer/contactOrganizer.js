import { LightningElement, api, track, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import loadOrganizer from '@salesforce/apex/ContactOrganizerController.loadOrganizer';
import saveAssignments from '@salesforce/apex/ContactOrganizerController.saveAssignments';

const UNASSIGNED = 'UNASSIGNED';
const ROLES = [
    { key: 'C-Suite/Executive', label: 'C-Suite / Executive' },
    { key: 'Technology/Ops', label: 'Technology / Ops' },
    { key: 'Senior User', label: 'Senior User' },
    { key: 'Junior User', label: 'Junior User' }
];

export default class ContactOrganizer extends LightningElement {
    @api recordId;

    @track contactsById = {};
    @track buckets = {};
    accountName;
    accountId;
    isLoading = true;
    isSaving = false;
    isDirty = false;
    errorMessage;
    wiredResult;
    draggedContactId;

    @wire(loadOrganizer, { opportunityId: '$recordId' })
    wiredLoad(result) {
        this.wiredResult = result;
        const { data, error } = result;
        if (data) {
            this.hydrate(data);
            this.isLoading = false;
            this.errorMessage = undefined;
        } else if (error) {
            this.isLoading = false;
            this.errorMessage = this.extractError(error);
        }
    }

    hydrate(data) {
        this.accountName = data.accountName;
        this.accountId = data.accountId;

        const contactsById = {};
        for (const c of data.contacts || []) {
            contactsById[c.id] = c;
        }
        this.contactsById = contactsById;

        const buckets = { [UNASSIGNED]: [] };
        for (const role of ROLES) {
            buckets[role.key] = [];
        }

        const assignedIds = new Set();
        for (const assignment of data.existingAssignments || []) {
            if (buckets[assignment.role] && contactsById[assignment.contactId]) {
                buckets[assignment.role].push(assignment.contactId);
                assignedIds.add(assignment.contactId);
            }
        }
        for (const c of data.contacts || []) {
            if (!assignedIds.has(c.id)) {
                buckets[UNASSIGNED].push(c.id);
            }
        }

        this.buckets = buckets;
        this.isDirty = false;
    }

    get columns() {
        const unassigned = {
            key: UNASSIGNED,
            label: 'Unassigned Contacts',
            isUnassigned: true,
            contacts: this.contactsFor(UNASSIGNED),
            count: (this.buckets[UNASSIGNED] || []).length,
            cssClass: 'bucket bucket--unassigned'
        };
        const roleColumns = ROLES.map((r) => ({
            key: r.key,
            label: r.label,
            isUnassigned: false,
            contacts: this.contactsFor(r.key),
            count: (this.buckets[r.key] || []).length,
            cssClass: 'bucket bucket--role'
        }));
        return [unassigned, ...roleColumns];
    }

    contactsFor(bucketKey) {
        const ids = this.buckets[bucketKey] || [];
        return ids
            .map((id) => this.contactsById[id])
            .filter(Boolean)
            .map((c) => ({
                ...c,
                cssClass: 'contact-tile'
            }));
    }

    get hasContacts() {
        return Object.keys(this.contactsById).length > 0;
    }

    get hasAccount() {
        return !!this.accountId;
    }

    get saveDisabled() {
        return this.isSaving || !this.isDirty;
    }

    handleDragStart(event) {
        this.draggedContactId = event.currentTarget.dataset.contactId;
        event.dataTransfer.effectAllowed = 'move';
        try {
            event.dataTransfer.setData('text/plain', this.draggedContactId);
        } catch (e) {
            // some browsers throw if called on a non-text drag — safe to ignore
        }
    }

    handleDragOver(event) {
        event.preventDefault();
        event.dataTransfer.dropEffect = 'move';
        event.currentTarget.classList.add('bucket--drop-target');
    }

    handleDragLeave(event) {
        event.currentTarget.classList.remove('bucket--drop-target');
    }

    handleDrop(event) {
        event.preventDefault();
        event.currentTarget.classList.remove('bucket--drop-target');
        const targetBucket = event.currentTarget.dataset.bucketKey;
        const contactId = this.draggedContactId || event.dataTransfer.getData('text/plain');
        this.draggedContactId = null;
        if (!contactId || !targetBucket) {
            return;
        }
        this.moveContact(contactId, targetBucket);
    }

    moveContact(contactId, targetBucket) {
        const next = {};
        let changed = false;
        for (const key of Object.keys(this.buckets)) {
            const before = this.buckets[key];
            const filtered = before.filter((id) => id !== contactId);
            if (filtered.length !== before.length) {
                changed = true;
            }
            next[key] = filtered;
        }
        if (!next[targetBucket]) {
            next[targetBucket] = [];
        }
        if (!next[targetBucket].includes(contactId)) {
            next[targetBucket].push(contactId);
            changed = true;
        }
        if (changed) {
            this.buckets = next;
            this.isDirty = true;
        }
    }

    async handleSave() {
        this.isSaving = true;
        const assignments = [];
        for (const role of ROLES) {
            for (const contactId of this.buckets[role.key] || []) {
                assignments.push({ contactId, role: role.key });
            }
        }
        try {
            await saveAssignments({
                opportunityId: this.recordId,
                assignments
            });
            this.isDirty = false;
            this.dispatchEvent(new ShowToastEvent({
                title: 'Saved',
                message: 'Relationship map updated.',
                variant: 'success'
            }));
            await refreshApex(this.wiredResult);
        } catch (error) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Save failed',
                message: this.extractError(error),
                variant: 'error'
            }));
        } finally {
            this.isSaving = false;
        }
    }

    async handleReset() {
        this.isLoading = true;
        try {
            await refreshApex(this.wiredResult);
        } finally {
            this.isLoading = false;
        }
    }

    extractError(error) {
        if (!error) return 'Unknown error';
        if (typeof error === 'string') return error;
        if (error.body) {
            if (Array.isArray(error.body)) {
                return error.body.map((e) => e.message).join(', ');
            }
            if (typeof error.body.message === 'string') {
                return error.body.message;
            }
        }
        return error.message || 'Unknown error';
    }
}
